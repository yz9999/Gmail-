#include "CurlShim.h"

#include <curl/curl.h>
#include <Security/Security.h>
#include <Security/SecureTransport.h>
#include <arpa/inet.h>
#include <errno.h>
#include <netdb.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

typedef struct {
    unsigned char *bytes;
    size_t length;
    size_t capacity;
} Buffer;

typedef struct {
    const unsigned char *bytes;
    size_t length;
    size_t offset;
} Upload;

static int buffer_reserve(Buffer *buffer, size_t additional) {
    if (additional > SIZE_MAX - buffer->length) return 0;
    size_t required = buffer->length + additional;
    if (required <= buffer->capacity) return 1;
    size_t capacity = buffer->capacity ? buffer->capacity : 4096;
    while (capacity < required) {
        if (capacity > SIZE_MAX / 2) { capacity = required; break; }
        capacity *= 2;
    }
    unsigned char *bytes = realloc(buffer->bytes, capacity);
    if (!bytes) return 0;
    buffer->bytes = bytes;
    buffer->capacity = capacity;
    return 1;
}

static size_t write_callback(char *pointer, size_t size, size_t count, void *userdata) {
    Buffer *buffer = userdata;
    if (size && count > SIZE_MAX / size) return 0;
    size_t length = size * count;
    if (!buffer_reserve(buffer, length)) return 0;
    memcpy(buffer->bytes + buffer->length, pointer, length);
    buffer->length += length;
    return length;
}

static size_t read_callback(char *pointer, size_t size, size_t count, void *userdata) {
    Upload *upload = userdata;
    if (size && count > SIZE_MAX / size) return CURL_READFUNC_ABORT;
    size_t available = upload->length - upload->offset;
    size_t requested = size * count;
    size_t length = available < requested ? available : requested;
    if (length) {
        memcpy(pointer, upload->bytes + upload->offset, length);
        upload->offset += length;
    }
    return length;
}

static char *duplicate_error(const char *value) {
    if (!value || !*value) return NULL;
    size_t length = strlen(value) + 1;
    char *copy = malloc(length);
    if (copy) memcpy(copy, value, length);
    return copy;
}

static GRResult failure(const char *message, long status) {
    GRResult result = {0};
    result.error = duplicate_error(message);
    result.status = status;
    return result;
}

static void configure_common(
    CURL *curl,
    Buffer *buffer,
    const char *username,
    const char *password,
    const char *proxy_host,
    int proxy_port,
    long timeout_seconds,
    char error_buffer[CURL_ERROR_SIZE]
) {
    curl_easy_setopt(curl, CURLOPT_USERNAME, username);
    curl_easy_setopt(curl, CURLOPT_PASSWORD, password);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, write_callback);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, buffer);
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 15L);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, timeout_seconds);
    curl_easy_setopt(curl, CURLOPT_LOW_SPEED_LIMIT, 1L);
    curl_easy_setopt(curl, CURLOPT_LOW_SPEED_TIME, 30L);
    curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 1L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYHOST, 2L);
    curl_easy_setopt(curl, CURLOPT_USERAGENT, "GmailReader-macOS/1.0");
    curl_easy_setopt(curl, CURLOPT_ERRORBUFFER, error_buffer);
    if (proxy_host && *proxy_host && proxy_port > 0) {
        char proxy[1024];
        snprintf(proxy, sizeof(proxy), "%s:%d", proxy_host, proxy_port);
        curl_easy_setopt(curl, CURLOPT_PROXY, proxy);
        curl_easy_setopt(curl, CURLOPT_PROXYTYPE, CURLPROXY_SOCKS5_HOSTNAME);
    }
}

int gr_curl_initialize(void) {
    return curl_global_init(CURL_GLOBAL_DEFAULT) == CURLE_OK;
}

GRResult gr_imap_request(
    const char *url,
    const char *username,
    const char *password,
    const char *proxy_host,
    int proxy_port,
    const char *custom_request,
    long timeout_seconds
) {
    if (!url || !username || !password) return failure("Invalid IMAP arguments", CURLE_BAD_FUNCTION_ARGUMENT);
    CURL *curl = curl_easy_init();
    if (!curl) return failure("Unable to create libcurl handle", CURLE_FAILED_INIT);

    Buffer buffer = {0};
    char error_buffer[CURL_ERROR_SIZE] = {0};
    configure_common(curl, &buffer, username, password, proxy_host, proxy_port, timeout_seconds, error_buffer);
    curl_easy_setopt(curl, CURLOPT_URL, url);
    if (custom_request && *custom_request) curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, custom_request);

    CURLcode code = curl_easy_perform(curl);
    curl_easy_cleanup(curl);
    if (code != CURLE_OK) {
        free(buffer.bytes);
        return failure(error_buffer[0] ? error_buffer : curl_easy_strerror(code), code);
    }
    GRResult result = {buffer.bytes, buffer.length, NULL, code};
    return result;
}

static int append_u32(Buffer *buffer, uint32_t value) {
    unsigned char bytes[4] = {
        (unsigned char)((value >> 24) & 0xff),
        (unsigned char)((value >> 16) & 0xff),
        (unsigned char)((value >> 8) & 0xff),
        (unsigned char)(value & 0xff),
    };
    if (!buffer_reserve(buffer, 4)) return 0;
    memcpy(buffer->bytes + buffer->length, bytes, 4);
    buffer->length += 4;
    return 1;
}

GRResult gr_imap_fetch_many(
    const char *base_url,
    const char *encoded_folder,
    const char *comma_separated_uids,
    const char *encoded_section,
    const char *username,
    const char *password,
    const char *proxy_host,
    int proxy_port,
    long timeout_seconds
) {
    if (!base_url || !encoded_folder || !comma_separated_uids || !encoded_section) {
        return failure("Invalid batch IMAP arguments", CURLE_BAD_FUNCTION_ARGUMENT);
    }
    CURL *curl = curl_easy_init();
    if (!curl) return failure("Unable to create libcurl handle", CURLE_FAILED_INIT);
    char *uids = strdup(comma_separated_uids);
    if (!uids) { curl_easy_cleanup(curl); return failure("Out of memory", CURLE_OUT_OF_MEMORY); }

    Buffer output = {0};
    Buffer item = {0};
    char error_buffer[CURL_ERROR_SIZE] = {0};
    configure_common(curl, &item, username, password, proxy_host, proxy_port, timeout_seconds, error_buffer);

    CURLcode code = CURLE_OK;
    char *save = NULL;
    for (char *uid = strtok_r(uids, ",", &save); uid; uid = strtok_r(NULL, ",", &save)) {
        for (const char *p = uid; *p; ++p) {
            if (*p < '0' || *p > '9') { code = CURLE_URL_MALFORMAT; break; }
        }
        if (code != CURLE_OK) break;
        size_t url_length = strlen(base_url) + strlen(encoded_folder) + strlen(uid) + strlen(encoded_section) + 32;
        char *url = malloc(url_length);
        if (!url) { code = CURLE_OUT_OF_MEMORY; break; }
        snprintf(url, url_length, "%s/%s;UID=%s/;SECTION=%s", base_url, encoded_folder, uid, encoded_section);
        item.length = 0;
        error_buffer[0] = '\0';
        curl_easy_setopt(curl, CURLOPT_URL, url);
        curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, NULL);
        code = curl_easy_perform(curl);
        free(url);
        if (code != CURLE_OK) break;
        if (item.length > UINT32_MAX || !append_u32(&output, (uint32_t)item.length) ||
            !buffer_reserve(&output, item.length)) {
            code = CURLE_OUT_OF_MEMORY;
            break;
        }
        memcpy(output.bytes + output.length, item.bytes, item.length);
        output.length += item.length;
    }

    free(item.bytes);
    free(uids);
    curl_easy_cleanup(curl);
    if (code != CURLE_OK) {
        free(output.bytes);
        return failure(error_buffer[0] ? error_buffer : curl_easy_strerror(code), code);
    }
    GRResult result = {output.bytes, output.length, NULL, code};
    return result;
}

static int socket_write_all(int socket_fd, const unsigned char *bytes, size_t length) {
    while (length) {
        ssize_t written = send(socket_fd, bytes, length, 0);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) return 0;
        bytes += written;
        length -= (size_t)written;
    }
    return 1;
}

static int socket_read_all(int socket_fd, unsigned char *bytes, size_t length) {
    while (length) {
        ssize_t received = recv(socket_fd, bytes, length, 0);
        if (received < 0 && errno == EINTR) continue;
        if (received <= 0) return 0;
        bytes += received;
        length -= (size_t)received;
    }
    return 1;
}

static int connect_tcp(const char *host, int port, long timeout_seconds) {
    char port_string[16];
    snprintf(port_string, sizeof(port_string), "%d", port);
    struct addrinfo hints = {0};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    struct addrinfo *addresses = NULL;
    if (getaddrinfo(host, port_string, &hints, &addresses) != 0) return -1;
    int socket_fd = -1;
    for (struct addrinfo *address = addresses; address; address = address->ai_next) {
        socket_fd = socket(address->ai_family, address->ai_socktype, address->ai_protocol);
        if (socket_fd < 0) continue;
        struct timeval timeout = {timeout_seconds, 0};
        setsockopt(socket_fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        setsockopt(socket_fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
        if (connect(socket_fd, address->ai_addr, address->ai_addrlen) == 0) break;
        close(socket_fd);
        socket_fd = -1;
    }
    freeaddrinfo(addresses);
    return socket_fd;
}

static int socks5_connect(int socket_fd, const char *host, int port) {
    const unsigned char greeting[] = {5, 1, 0};
    unsigned char response[4];
    if (!socket_write_all(socket_fd, greeting, sizeof(greeting)) || !socket_read_all(socket_fd, response, 2) ||
        response[0] != 5 || response[1] != 0) return 0;
    size_t host_length = strlen(host);
    if (host_length == 0 || host_length > 255) return 0;
    size_t request_length = host_length + 7;
    unsigned char *request = malloc(request_length);
    if (!request) return 0;
    request[0] = 5; request[1] = 1; request[2] = 0; request[3] = 3; request[4] = (unsigned char)host_length;
    memcpy(request + 5, host, host_length);
    request[5 + host_length] = (unsigned char)((port >> 8) & 0xff);
    request[6 + host_length] = (unsigned char)(port & 0xff);
    int ok = socket_write_all(socket_fd, request, request_length);
    free(request);
    if (!ok || !socket_read_all(socket_fd, response, 4) || response[0] != 5 || response[1] != 0) return 0;
    size_t remaining;
    if (response[3] == 1) remaining = 4 + 2;
    else if (response[3] == 4) remaining = 16 + 2;
    else if (response[3] == 3) {
        unsigned char length;
        if (!socket_read_all(socket_fd, &length, 1)) return 0;
        remaining = (size_t)length + 2;
    } else return 0;
    unsigned char discard[258];
    return remaining <= sizeof(discard) && socket_read_all(socket_fd, discard, remaining);
}

static OSStatus ssl_socket_read(SSLConnectionRef connection, void *data, size_t *data_length) {
    int socket_fd = (int)(intptr_t)connection;
    ssize_t count;
    do { count = recv(socket_fd, data, *data_length, 0); } while (count < 0 && errno == EINTR);
    if (count > 0) { *data_length = (size_t)count; return noErr; }
    *data_length = 0;
    if (count == 0) return errSSLClosedGraceful;
    return errSecIO;
}

static OSStatus ssl_socket_write(SSLConnectionRef connection, const void *data, size_t *data_length) {
    int socket_fd = (int)(intptr_t)connection;
    ssize_t count;
    do { count = send(socket_fd, data, *data_length, 0); } while (count < 0 && errno == EINTR);
    if (count >= 0) { *data_length = (size_t)count; return noErr; }
    *data_length = 0;
    return errSecIO;
}

static int tls_handshake(SSLContextRef context, const char *host) {
    SSLSetSessionOption(context, kSSLSessionOptionBreakOnServerAuth, true);
    OSStatus status = SSLHandshake(context);
    if (status == errSSLServerAuthCompleted) {
        SecTrustRef trust = NULL;
        if (SSLCopyPeerTrust(context, &trust) != noErr || !trust) return 0;
        CFStringRef hostname = CFStringCreateWithCString(NULL, host, kCFStringEncodingUTF8);
        SecPolicyRef policy = hostname ? SecPolicyCreateSSL(true, hostname) : NULL;
        if (hostname) CFRelease(hostname);
        if (!policy) { CFRelease(trust); return 0; }
        SecTrustSetPolicies(trust, policy);
        SecTrustResultType result = kSecTrustResultInvalid;
        OSStatus trust_status = SecTrustEvaluate(trust, &result);
        CFRelease(policy);
        CFRelease(trust);
        if (trust_status != errSecSuccess ||
            (result != kSecTrustResultProceed && result != kSecTrustResultUnspecified)) return 0;
        status = SSLHandshake(context);
    }
    return status == noErr;
}

static int ssl_write_all(SSLContextRef context, const unsigned char *bytes, size_t length) {
    while (length) {
        size_t written = 0;
        OSStatus status = SSLWrite(context, bytes, length, &written);
        if (status != noErr || written == 0) return 0;
        bytes += written;
        length -= written;
    }
    return 1;
}

static int ssl_read_until(SSLContextRef context, const char *prefix, Buffer *buffer) {
    size_t prefix_length = strlen(prefix);
    size_t line_start = buffer->length;
    for (;;) {
        unsigned char byte;
        size_t received = 0;
        OSStatus status = SSLRead(context, &byte, 1, &received);
        if (status != noErr || received != 1 || !buffer_reserve(buffer, 1)) return 0;
        buffer->bytes[buffer->length++] = byte;
        if (byte == '\n') {
            size_t line_length = buffer->length - line_start;
            if (line_length >= prefix_length && memcmp(buffer->bytes + line_start, prefix, prefix_length) == 0) return 1;
            line_start = buffer->length;
        }
    }
}

static char *imap_quote(const char *value) {
    size_t length = 2;
    for (const char *p = value; *p; ++p) length += (*p == '\\' || *p == '"') ? 2 : 1;
    char *quoted = malloc(length + 1);
    if (!quoted) return NULL;
    char *out = quoted;
    *out++ = '"';
    for (const char *p = value; *p; ++p) {
        if (*p == '\\' || *p == '"') *out++ = '\\';
        *out++ = *p;
    }
    *out++ = '"'; *out = '\0';
    return quoted;
}

static int imap_command(SSLContextRef context, const char *command, const char *completion_prefix, Buffer *response) {
    if (!ssl_write_all(context, (const unsigned char *)command, strlen(command))) return 0;
    return ssl_read_until(context, completion_prefix, response);
}

static int imap_open_authenticated(
    const char *host, int port, const char *folder, const char *username, const char *password,
    const char *proxy_host, int proxy_port, long timeout_seconds,
    int *socket_out, SSLContextRef *ssl_out, const char **failed_stage
) {
    *socket_out = -1;
    *ssl_out = NULL;
    *failed_stage = "connecting to Gmail";
    const char *connect_host = proxy_host && *proxy_host ? proxy_host : host;
    int connect_port = proxy_host && *proxy_host ? proxy_port : port;
    int socket_fd = connect_tcp(connect_host, connect_port, timeout_seconds);
    if (socket_fd < 0) return 0;
    if (proxy_host && *proxy_host && !socks5_connect(socket_fd, host, port)) {
        close(socket_fd);
        *failed_stage = "negotiating the SOCKS5 proxy";
        return 0;
    }

    *failed_stage = "establishing verified Gmail TLS";
    SSLContextRef ssl = SSLCreateContext(NULL, kSSLClientSide, kSSLStreamType);
    if (!ssl) { close(socket_fd); return 0; }
    SSLSetIOFuncs(ssl, ssl_socket_read, ssl_socket_write);
    SSLSetConnection(ssl, (SSLConnectionRef)(intptr_t)socket_fd);
    SSLSetPeerDomainName(ssl, host, strlen(host));
    SSLSetProtocolVersionMin(ssl, kTLSProtocol12);
    if (!tls_handshake(ssl, host)) { CFRelease(ssl); close(socket_fd); return 0; }

    Buffer scratch = {0};
    char *quoted_user = imap_quote(username);
    char *quoted_password = imap_quote(password);
    char *quoted_folder = imap_quote(folder);
    char *command = NULL;
    *failed_stage = "reading Gmail greeting";
    int ok = quoted_user && quoted_password && quoted_folder && ssl_read_until(ssl, "* ", &scratch);
    if (ok) {
        *failed_stage = "authenticating Gmail account";
        size_t length = strlen(quoted_user) + strlen(quoted_password) + 32;
        command = malloc(length);
        if (command) snprintf(command, length, "A001 LOGIN %s %s\r\n", quoted_user, quoted_password);
        scratch.length = 0;
        ok = command && imap_command(ssl, command, "A001 ", &scratch) &&
             memmem(scratch.bytes, scratch.length, "A001 OK", 7) != NULL;
        free(command); command = NULL;
    }
    if (ok) {
        *failed_stage = "selecting Gmail mailbox";
        size_t length = strlen(quoted_folder) + 32;
        command = malloc(length);
        if (command) snprintf(command, length, "A002 SELECT %s\r\n", quoted_folder);
        scratch.length = 0;
        ok = command && imap_command(ssl, command, "A002 ", &scratch) &&
             memmem(scratch.bytes, scratch.length, "A002 OK", 7) != NULL;
    }
    free(command);
    free(scratch.bytes);
    free(quoted_user); free(quoted_password); free(quoted_folder);
    if (!ok) {
        SSLClose(ssl); CFRelease(ssl); close(socket_fd);
        return 0;
    }
    *socket_out = socket_fd;
    *ssl_out = ssl;
    return 1;
}

static void imap_close_authenticated(int socket_fd, SSLContextRef ssl) {
    ssl_write_all(ssl, (const unsigned char *)"A004 LOGOUT\r\n", 13);
    SSLClose(ssl);
    CFRelease(ssl);
    close(socket_fd);
}

GRResult gr_imap_search_utf8(
    const char *host,
    int port,
    const char *encoded_folder,
    const char *query,
    const char *username,
    const char *password,
    const char *proxy_host,
    int proxy_port,
    long timeout_seconds
) {
    if (!host || !encoded_folder || !query || !username || !password) {
        return failure("Invalid UTF-8 IMAP search arguments", CURLE_BAD_FUNCTION_ARGUMENT);
    }
    Buffer response = {0};
    const char *failed_stage = NULL;
    int socket_fd;
    SSLContextRef ssl;
    int ok = imap_open_authenticated(host, port, encoded_folder, username, password, proxy_host, proxy_port,
                                     timeout_seconds, &socket_fd, &ssl, &failed_stage);
    if (ok) {
        failed_stage = "starting Gmail UTF-8 search";
        char search_command[128];
        snprintf(search_command, sizeof(search_command), "A003 UID SEARCH CHARSET UTF-8 X-GM-RAW {%zu}\r\n", strlen(query));
        Buffer scratch = {0};
        ok = imap_command(ssl, search_command, "+", &scratch);
        free(scratch.bytes);
        if (ok) {
            failed_stage = "receiving Gmail UTF-8 search results";
            ok = ssl_write_all(ssl, (const unsigned char *)query, strlen(query)) &&
                 ssl_write_all(ssl, (const unsigned char *)"\r\n", 2) &&
                 ssl_read_until(ssl, "A003 ", &response) &&
                 memmem(response.bytes, response.length, "A003 OK", 7) != NULL;
        }
    }
    if (ssl) imap_close_authenticated(socket_fd, ssl);
    if (!ok) {
        free(response.bytes);
        return failure(failed_stage, CURLE_QUOTE_ERROR);
    }
    GRResult result = {response.bytes, response.length, NULL, CURLE_OK};
    return result;
}

GRResult gr_imap_fetch_summaries(
    const char *host, int port, const char *encoded_folder, const char *comma_separated_uids,
    const char *username, const char *password, const char *proxy_host, int proxy_port, long timeout_seconds
) {
    if (!host || !encoded_folder || !comma_separated_uids || !username || !password) {
        return failure("Invalid IMAP summary arguments", CURLE_BAD_FUNCTION_ARGUMENT);
    }
    for (const char *p = comma_separated_uids; *p; ++p) {
        if ((*p < '0' || *p > '9') && *p != ',') return failure("Invalid IMAP UID set", CURLE_BAD_FUNCTION_ARGUMENT);
    }
    const char *failed_stage = NULL;
    int socket_fd;
    SSLContextRef ssl = NULL;
    if (!imap_open_authenticated(host, port, encoded_folder, username, password, proxy_host, proxy_port,
                                 timeout_seconds, &socket_fd, &ssl, &failed_stage)) {
        return failure(failed_stage, CURLE_QUOTE_ERROR);
    }
    size_t length = strlen(comma_separated_uids) + 128;
    char *command = malloc(length);
    Buffer response = {0};
    int ok = command != NULL;
    if (ok) {
        snprintf(command, length,
                 "A003 UID FETCH %s (UID FLAGS BODY.PEEK[HEADER.FIELDS (FROM TO SUBJECT DATE MESSAGE-ID)])\r\n",
                 comma_separated_uids);
        failed_stage = "fetching Gmail message summaries";
        ok = imap_command(ssl, command, "A003 ", &response) &&
             memmem(response.bytes, response.length, "A003 OK", 7) != NULL;
    }
    free(command);
    imap_close_authenticated(socket_fd, ssl);
    if (!ok) { free(response.bytes); return failure(failed_stage, CURLE_QUOTE_ERROR); }
    GRResult result = {response.bytes, response.length, NULL, CURLE_OK};
    return result;
}

GRResult gr_smtp_send(
    const char *url,
    const char *username,
    const char *password,
    const char *proxy_host,
    int proxy_port,
    const char *sender,
    const char *newline_separated_recipients,
    const unsigned char *message,
    size_t message_length,
    long timeout_seconds
) {
    if (!url || !username || !password || !sender || !newline_separated_recipients || !message) {
        return failure("Invalid SMTP arguments", CURLE_BAD_FUNCTION_ARGUMENT);
    }
    CURL *curl = curl_easy_init();
    if (!curl) return failure("Unable to create libcurl handle", CURLE_FAILED_INIT);

    Buffer response = {0};
    Upload upload = {message, message_length, 0};
    char error_buffer[CURL_ERROR_SIZE] = {0};
    configure_common(curl, &response, username, password, proxy_host, proxy_port, timeout_seconds, error_buffer);

    struct curl_slist *recipients = NULL;
    char *copy = strdup(newline_separated_recipients);
    if (!copy) { curl_easy_cleanup(curl); return failure("Out of memory", CURLE_OUT_OF_MEMORY); }
    char *save = NULL;
    for (char *recipient = strtok_r(copy, "\n", &save); recipient; recipient = strtok_r(NULL, "\n", &save)) {
        if (*recipient) recipients = curl_slist_append(recipients, recipient);
    }

    curl_easy_setopt(curl, CURLOPT_URL, url);
    curl_easy_setopt(curl, CURLOPT_MAIL_FROM, sender);
    curl_easy_setopt(curl, CURLOPT_MAIL_RCPT, recipients);
    curl_easy_setopt(curl, CURLOPT_UPLOAD, 1L);
    curl_easy_setopt(curl, CURLOPT_READFUNCTION, read_callback);
    curl_easy_setopt(curl, CURLOPT_READDATA, &upload);
    curl_easy_setopt(curl, CURLOPT_INFILESIZE_LARGE, (curl_off_t)message_length);

    CURLcode code = curl_easy_perform(curl);
    curl_slist_free_all(recipients);
    free(copy);
    curl_easy_cleanup(curl);
    if (code != CURLE_OK) {
        free(response.bytes);
        return failure(error_buffer[0] ? error_buffer : curl_easy_strerror(code), code);
    }
    GRResult result = {response.bytes, response.length, NULL, code};
    return result;
}

void gr_result_free(GRResult result) {
    free(result.data);
    free(result.error);
}
