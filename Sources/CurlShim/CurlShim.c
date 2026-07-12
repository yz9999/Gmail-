#include "CurlShim.h"

#include <curl/curl.h>
#include <errno.h>
#include <limits.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <time.h>

#define GR_MAX_IMAP_RESPONSE (64u * 1024u * 1024u)

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

typedef struct {
    uint64_t *values;
    size_t count;
    size_t capacity;
} UIDList;

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

static int buffer_append(Buffer *buffer, const void *bytes, size_t length) {
    if (!buffer_reserve(buffer, length)) return 0;
    if (length) memcpy(buffer->bytes + buffer->length, bytes, length);
    buffer->length += length;
    return 1;
}

static size_t write_callback(char *pointer, size_t size, size_t count, void *userdata) {
    Buffer *buffer = userdata;
    if (size && count > SIZE_MAX / size) return 0;
    size_t length = size * count;
    if (length > GR_MAX_IMAP_RESPONSE || buffer->length > GR_MAX_IMAP_RESPONSE - length) return 0;
    return buffer_append(buffer, pointer, length) ? length : 0;
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
    result.error = duplicate_error(message && *message ? message : "Unknown Gmail transport error");
    result.status = status;
    return result;
}

static void secure_clear(void *pointer, size_t length) {
    volatile unsigned char *bytes = pointer;
    while (length--) *bytes++ = 0;
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
    if (username) curl_easy_setopt(curl, CURLOPT_USERNAME, username);
    if (password) curl_easy_setopt(curl, CURLOPT_PASSWORD, password);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, write_callback);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, buffer);
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 12L);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, timeout_seconds);
    curl_easy_setopt(curl, CURLOPT_LOW_SPEED_LIMIT, 1L);
    curl_easy_setopt(curl, CURLOPT_LOW_SPEED_TIME, 20L);
    curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 1L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYHOST, 2L);
    curl_easy_setopt(curl, CURLOPT_SSLVERSION, CURL_SSLVERSION_TLSv1_2);
    curl_easy_setopt(curl, CURLOPT_TCP_KEEPALIVE, 1L);
    curl_easy_setopt(curl, CURLOPT_DNS_CACHE_TIMEOUT, 300L);
    curl_easy_setopt(curl, CURLOPT_USERAGENT, "GmailReader-macOS/1.1");
    curl_easy_setopt(curl, CURLOPT_ERRORBUFFER, error_buffer);
    if (proxy_host && *proxy_host && proxy_port > 0) {
        char proxy[1024];
        snprintf(proxy, sizeof(proxy), "%s:%d", proxy_host, proxy_port);
        curl_easy_setopt(curl, CURLOPT_PROXY, proxy);
        curl_easy_setopt(curl, CURLOPT_PROXYTYPE, CURLPROXY_SOCKS5_HOSTNAME);
    } else {
        /* Do not accidentally inherit ALL_PROXY/HTTPS_PROXY when the app says direct connection. */
        curl_easy_setopt(curl, CURLOPT_PROXY, "");
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
    return buffer_append(buffer, bytes, sizeof(bytes));
}

static int append_u64(Buffer *buffer, uint64_t value) {
    unsigned char bytes[8] = {
        (unsigned char)((value >> 56) & 0xff),
        (unsigned char)((value >> 48) & 0xff),
        (unsigned char)((value >> 40) & 0xff),
        (unsigned char)((value >> 32) & 0xff),
        (unsigned char)((value >> 24) & 0xff),
        (unsigned char)((value >> 16) & 0xff),
        (unsigned char)((value >> 8) & 0xff),
        (unsigned char)(value & 0xff),
    };
    return buffer_append(buffer, bytes, sizeof(bytes));
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
            !buffer_append(&output, item.bytes, item.length)) {
            code = CURLE_OUT_OF_MEMORY;
            break;
        }
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

static double monotonic_seconds(void) {
    struct timespec value;
    clock_gettime(CLOCK_MONOTONIC, &value);
    return (double)value.tv_sec + (double)value.tv_nsec / 1000000000.0;
}

static int wait_for_socket(CURL *curl, short events, double deadline) {
    curl_socket_t socket_fd = CURL_SOCKET_BAD;
    if (curl_easy_getinfo(curl, CURLINFO_ACTIVESOCKET, &socket_fd) != CURLE_OK || socket_fd == CURL_SOCKET_BAD) return 0;
    for (;;) {
        double remaining = deadline - monotonic_seconds();
        if (remaining <= 0) return 0;
        long milliseconds = (long)(remaining * 1000.0);
        if (milliseconds < 1) milliseconds = 1;
        if (milliseconds > INT_MAX) milliseconds = INT_MAX;
        struct pollfd descriptor = {socket_fd, events, 0};
        int result = poll(&descriptor, 1, (int)milliseconds);
        if (result > 0) return (descriptor.revents & (events | POLLERR | POLLHUP)) != 0;
        if (result == 0) return 0;
        if (errno != EINTR) return 0;
    }
}

static CURLcode raw_send_all(CURL *curl, const unsigned char *bytes, size_t length, long timeout_seconds) {
    size_t offset = 0;
    double deadline = monotonic_seconds() + (double)timeout_seconds;
    while (offset < length) {
        size_t sent = 0;
        CURLcode code = curl_easy_send(curl, bytes + offset, length - offset, &sent);
        if (code == CURLE_AGAIN) {
            if (!wait_for_socket(curl, POLLOUT, deadline)) return CURLE_OPERATION_TIMEDOUT;
            continue;
        }
        if (code != CURLE_OK) return code;
        if (sent == 0) return CURLE_SEND_ERROR;
        offset += sent;
    }
    return CURLE_OK;
}

/* Returns 1 for tagged OK, -1 for tagged NO/BAD, and 0 while incomplete. */
static int tagged_status(const Buffer *buffer, const char *tag) {
    size_t tag_length = strlen(tag);
    size_t line_start = 0;
    while (line_start < buffer->length) {
        size_t line_end = line_start;
        while (line_end < buffer->length && buffer->bytes[line_end] != '\n') line_end++;
        if (line_end == buffer->length) return 0;
        size_t length = line_end - line_start;
        if (length > tag_length + 3 && memcmp(buffer->bytes + line_start, tag, tag_length) == 0 &&
            buffer->bytes[line_start + tag_length] == ' ') {
            const unsigned char *status = buffer->bytes + line_start + tag_length + 1;
            if (length >= tag_length + 3 && strncasecmp((const char *)status, "OK", 2) == 0) return 1;
            if (length >= tag_length + 3 && (strncasecmp((const char *)status, "NO", 2) == 0 ||
                strncasecmp((const char *)status, "BAD", 3) == 0)) return -1;
        }
        line_start = line_end + 1;
    }
    return 0;
}

static int has_continuation(const Buffer *buffer) {
    size_t line_start = 0;
    while (line_start < buffer->length) {
        size_t line_end = line_start;
        while (line_end < buffer->length && buffer->bytes[line_end] != '\n') line_end++;
        if (line_end == buffer->length) return 0;
        if (line_end > line_start && buffer->bytes[line_start] == '+') return 1;
        line_start = line_end + 1;
    }
    return 0;
}

static CURLcode raw_receive(CURL *curl, const char *tag, int wait_for_continuation,
                            Buffer *response, long timeout_seconds, int *protocol_status) {
    unsigned char temporary[16384];
    double deadline = monotonic_seconds() + (double)timeout_seconds;
    *protocol_status = 0;
    for (;;) {
        size_t received = 0;
        CURLcode code = curl_easy_recv(curl, temporary, sizeof(temporary), &received);
        if (code == CURLE_AGAIN) {
            if (!wait_for_socket(curl, POLLIN, deadline)) return CURLE_OPERATION_TIMEDOUT;
            continue;
        }
        if (code != CURLE_OK) return code;
        if (received == 0) return CURLE_RECV_ERROR;
        if (received > GR_MAX_IMAP_RESPONSE || response->length > GR_MAX_IMAP_RESPONSE - received ||
            !buffer_append(response, temporary, received)) return CURLE_OUT_OF_MEMORY;
        int status = tagged_status(response, tag);
        if (status != 0) { *protocol_status = status; return CURLE_OK; }
        if (wait_for_continuation && has_continuation(response)) { *protocol_status = 1; return CURLE_OK; }
    }
}

static char *imap_quote(const char *value) {
    if (!value) return NULL;
    size_t length = 2;
    for (const char *p = value; *p; ++p) {
        size_t increment = (*p == '\\' || *p == '"') ? 2 : 1;
        if (length > SIZE_MAX - increment) return NULL;
        length += increment;
    }
    char *quoted = malloc(length + 1);
    if (!quoted) return NULL;
    char *out = quoted;
    *out++ = '"';
    for (const char *p = value; *p; ++p) {
        if (*p == '\\' || *p == '"') *out++ = '\\';
        *out++ = *p;
    }
    *out++ = '"';
    *out = '\0';
    return quoted;
}

static CURLcode raw_command(CURL *curl, const char *command, const char *tag,
                            Buffer *response, long timeout_seconds, int *protocol_status) {
    CURLcode code = raw_send_all(curl, (const unsigned char *)command, strlen(command), timeout_seconds);
    if (code != CURLE_OK) return code;
    return raw_receive(curl, tag, 0, response, timeout_seconds, protocol_status);
}

static CURL *raw_imap_open(
    const char *host, int port, const char *folder, const char *username, const char *password,
    const char *proxy_host, int proxy_port, long timeout_seconds,
    CURLcode *code_out, const char **failed_stage, char error_buffer[CURL_ERROR_SIZE]
) {
    *code_out = CURLE_FAILED_INIT;
    *failed_stage = "creating Gmail connection";
    CURL *curl = curl_easy_init();
    if (!curl) return NULL;

    Buffer sink = {0};
    configure_common(curl, &sink, username, password, proxy_host, proxy_port, timeout_seconds, error_buffer);
    size_t url_length = strlen(host) + 40;
    char *url = malloc(url_length);
    if (!url) { curl_easy_cleanup(curl); *code_out = CURLE_OUT_OF_MEMORY; return NULL; }
    snprintf(url, url_length, "imaps://%s:%d", host, port);
    curl_easy_setopt(curl, CURLOPT_URL, url);
    curl_easy_setopt(curl, CURLOPT_CONNECT_ONLY, 1L);
    *failed_stage = "establishing verified Gmail TLS";
    CURLcode code = curl_easy_perform(curl);
    free(url);
    free(sink.bytes);
    if (code != CURLE_OK) {
        *code_out = code;
        curl_easy_cleanup(curl);
        return NULL;
    }

    char *quoted_folder = imap_quote(folder);
    char *command = NULL;
    Buffer response = {0};
    int protocol_status = 0;
    if (!quoted_folder) code = CURLE_OUT_OF_MEMORY;

    if (code == CURLE_OK) {
        *failed_stage = "selecting Gmail mailbox";
        size_t command_length = strlen(quoted_folder) + 32;
        command = malloc(command_length);
        if (!command) code = CURLE_OUT_OF_MEMORY;
        else {
            snprintf(command, command_length, "S001 SELECT %s\r\n", quoted_folder);
            code = raw_command(curl, command, "S001", &response, timeout_seconds, &protocol_status);
            free(command);
            command = NULL;
        }
    }

    /*
     * Current macOS libcurl authenticates IMAP before returning from
     * CONNECT_ONLY. Older system libcurl releases may stop after TLS instead.
     * Fall back to an explicit LOGIN only when the initial SELECT was rejected.
     */
    if (code == CURLE_OK && protocol_status != 1) {
        char *quoted_user = imap_quote(username);
        char *quoted_password = imap_quote(password);
        int login_status = 0;
        response.length = 0;
        *failed_stage = "authenticating Gmail account";
        if (!quoted_user || !quoted_password) code = CURLE_OUT_OF_MEMORY;
        else {
            size_t command_length = strlen(quoted_user) + strlen(quoted_password) + 32;
            command = malloc(command_length);
            if (!command) code = CURLE_OUT_OF_MEMORY;
            else {
                snprintf(command, command_length, "L001 LOGIN %s %s\r\n", quoted_user, quoted_password);
                code = raw_command(curl, command, "L001", &response, timeout_seconds, &login_status);
                secure_clear(command, command_length);
                free(command);
                command = NULL;
            }
        }
        if (quoted_password) { secure_clear(quoted_password, strlen(quoted_password)); free(quoted_password); }
        free(quoted_user);
        if (code == CURLE_OK && login_status == 1) {
            response.length = 0;
            protocol_status = 0;
            *failed_stage = "selecting Gmail mailbox";
            size_t command_length = strlen(quoted_folder) + 32;
            command = malloc(command_length);
            if (!command) code = CURLE_OUT_OF_MEMORY;
            else {
                snprintf(command, command_length, "S002 SELECT %s\r\n", quoted_folder);
                code = raw_command(curl, command, "S002", &response, timeout_seconds, &protocol_status);
                free(command);
                command = NULL;
            }
        } else if (code == CURLE_OK) {
            code = CURLE_REMOTE_FILE_NOT_FOUND;
        }
    }
    if (code == CURLE_OK && protocol_status != 1) code = CURLE_REMOTE_FILE_NOT_FOUND;

    free(response.bytes);
    free(quoted_folder);
    if (code != CURLE_OK) {
        *code_out = code;
        curl_easy_cleanup(curl);
        return NULL;
    }
    *code_out = CURLE_OK;
    return curl;
}

static CURLcode raw_literal_search(CURL *curl, const char *query, Buffer *response,
                                   long timeout_seconds, int *protocol_status) {
    char command[160];
    snprintf(command, sizeof(command), "A003 UID SEARCH CHARSET UTF-8 X-GM-RAW {%zu}\r\n", strlen(query));
    CURLcode code = raw_send_all(curl, (const unsigned char *)command, strlen(command), timeout_seconds);
    if (code != CURLE_OK) return code;
    Buffer continuation = {0};
    code = raw_receive(curl, "A003", 1, &continuation, timeout_seconds, protocol_status);
    free(continuation.bytes);
    if (code != CURLE_OK || *protocol_status != 1) return code == CURLE_OK ? CURLE_QUOTE_ERROR : code;
    code = raw_send_all(curl, (const unsigned char *)query, strlen(query), timeout_seconds);
    if (code == CURLE_OK) code = raw_send_all(curl, (const unsigned char *)"\r\n", 2, timeout_seconds);
    if (code != CURLE_OK) return code;
    *protocol_status = 0;
    return raw_receive(curl, "A003", 0, response, timeout_seconds, protocol_status);
}

static int valid_search_criteria(const char *criteria) {
    if (!criteria || !*criteria || strlen(criteria) > 1024) return 0;
    for (const unsigned char *p = (const unsigned char *)criteria; *p; ++p) {
        if (*p == '\r' || *p == '\n' || *p == 0) return 0;
    }
    return 1;
}

static CURLcode raw_criteria_search(CURL *curl, const char *criteria, Buffer *response,
                                    long timeout_seconds, int *protocol_status) {
    if (!valid_search_criteria(criteria)) return CURLE_BAD_FUNCTION_ARGUMENT;
    size_t length = strlen(criteria) + 32;
    char *command = malloc(length);
    if (!command) return CURLE_OUT_OF_MEMORY;
    snprintf(command, length, "A003 UID SEARCH %s\r\n", criteria);
    CURLcode code = raw_command(curl, command, "A003", response, timeout_seconds, protocol_status);
    free(command);
    return code;
}

static int uid_list_append(UIDList *list, uint64_t value) {
    if (list->count == list->capacity) {
        size_t capacity = list->capacity ? list->capacity * 2 : 256;
        if (capacity < list->capacity || capacity > SIZE_MAX / sizeof(uint64_t)) return 0;
        uint64_t *values = realloc(list->values, capacity * sizeof(uint64_t));
        if (!values) return 0;
        list->values = values;
        list->capacity = capacity;
    }
    list->values[list->count++] = value;
    return 1;
}

static int parse_search_uids(const Buffer *response, UIDList *uids) {
    size_t line_start = 0;
    while (line_start < response->length) {
        size_t line_end = line_start;
        while (line_end < response->length && response->bytes[line_end] != '\n') line_end++;
        size_t length = line_end - line_start;
        if (length >= 8 && strncasecmp((const char *)response->bytes + line_start, "* SEARCH", 8) == 0) {
            size_t cursor = line_start + 8;
            while (cursor < line_end) {
                while (cursor < line_end && (response->bytes[cursor] == ' ' || response->bytes[cursor] == '\r')) cursor++;
                if (cursor >= line_end) break;
                if (response->bytes[cursor] < '0' || response->bytes[cursor] > '9') return 0;
                uint64_t value = 0;
                while (cursor < line_end && response->bytes[cursor] >= '0' && response->bytes[cursor] <= '9') {
                    unsigned digit = (unsigned)(response->bytes[cursor] - '0');
                    if (value > (UINT64_MAX - digit) / 10) return 0;
                    value = value * 10 + digit;
                    cursor++;
                }
                if (!uid_list_append(uids, value)) return 0;
            }
            return 1;
        }
        line_start = line_end + 1;
    }
    return 0;
}

static char *make_fetch_command(const UIDList *uids, size_t start, size_t end) {
    size_t count = end > start ? end - start : 0;
    if (!count || count > (SIZE_MAX - 160) / 24) return NULL;
    size_t capacity = count * 24 + 160;
    char *command = malloc(capacity);
    if (!command) return NULL;
    size_t offset = (size_t)snprintf(command, capacity, "A004 UID FETCH ");
    for (size_t index = end; index > start; --index) {
        int written = snprintf(command + offset, capacity - offset, "%s%llu",
                               index == end ? "" : ",", (unsigned long long)uids->values[index - 1]);
        if (written < 0 || (size_t)written >= capacity - offset) { free(command); return NULL; }
        offset += (size_t)written;
    }
    const char *suffix = " (UID FLAGS BODY.PEEK[HEADER.FIELDS (FROM TO SUBJECT DATE MESSAGE-ID)])\r\n";
    if (strlen(suffix) >= capacity - offset) { free(command); return NULL; }
    memcpy(command + offset, suffix, strlen(suffix) + 1);
    return command;
}

GRResult gr_imap_search_utf8(
    const char *host, int port, const char *folder, const char *query,
    const char *username, const char *password, const char *proxy_host, int proxy_port,
    long timeout_seconds
) {
    if (!host || !folder || !query || !username || !password) {
        return failure("Invalid UTF-8 IMAP search arguments", CURLE_BAD_FUNCTION_ARGUMENT);
    }
    char error_buffer[CURL_ERROR_SIZE] = {0};
    const char *failed_stage = NULL;
    CURLcode code;
    CURL *curl = raw_imap_open(host, port, folder, username, password, proxy_host, proxy_port,
                               timeout_seconds, &code, &failed_stage, error_buffer);
    if (!curl) return failure(error_buffer[0] ? error_buffer : failed_stage, code);

    Buffer response = {0};
    int protocol_status = 0;
    failed_stage = "searching Gmail";
    code = raw_literal_search(curl, query, &response, timeout_seconds, &protocol_status);
    curl_easy_cleanup(curl);
    if (code != CURLE_OK || protocol_status != 1) {
        free(response.bytes);
        return failure(error_buffer[0] ? error_buffer : failed_stage, code == CURLE_OK ? CURLE_QUOTE_ERROR : code);
    }
    GRResult result = {response.bytes, response.length, NULL, CURLE_OK};
    return result;
}

GRResult gr_imap_fetch_summaries(
    const char *host, int port, const char *folder, const char *comma_separated_uids,
    const char *username, const char *password, const char *proxy_host, int proxy_port,
    long timeout_seconds
) {
    if (!host || !folder || !comma_separated_uids || !username || !password) {
        return failure("Invalid IMAP summary arguments", CURLE_BAD_FUNCTION_ARGUMENT);
    }
    for (const char *p = comma_separated_uids; *p; ++p) {
        if ((*p < '0' || *p > '9') && *p != ',') return failure("Invalid IMAP UID set", CURLE_BAD_FUNCTION_ARGUMENT);
    }
    char error_buffer[CURL_ERROR_SIZE] = {0};
    const char *failed_stage = NULL;
    CURLcode code;
    CURL *curl = raw_imap_open(host, port, folder, username, password, proxy_host, proxy_port,
                               timeout_seconds, &code, &failed_stage, error_buffer);
    if (!curl) return failure(error_buffer[0] ? error_buffer : failed_stage, code);

    size_t length = strlen(comma_separated_uids) + 160;
    char *command = malloc(length);
    Buffer response = {0};
    int protocol_status = 0;
    if (!command) code = CURLE_OUT_OF_MEMORY;
    else {
        snprintf(command, length,
                 "A003 UID FETCH %s (UID FLAGS BODY.PEEK[HEADER.FIELDS (FROM TO SUBJECT DATE MESSAGE-ID)])\r\n",
                 comma_separated_uids);
        failed_stage = "fetching Gmail message summaries";
        code = raw_command(curl, command, "A003", &response, timeout_seconds, &protocol_status);
    }
    free(command);
    curl_easy_cleanup(curl);
    if (code != CURLE_OK || protocol_status != 1) {
        free(response.bytes);
        return failure(error_buffer[0] ? error_buffer : failed_stage, code == CURLE_OK ? CURLE_QUOTE_ERROR : code);
    }
    GRResult result = {response.bytes, response.length, NULL, CURLE_OK};
    return result;
}

GRResult gr_imap_page(
    const char *host, int port, const char *folder, const char *search_criteria, const char *query,
    int page, int page_size, const char *username, const char *password,
    const char *proxy_host, int proxy_port, long timeout_seconds
) {
    if (!host || !folder || !username || !password || page < 1 || page_size < 1 || page_size > 500 ||
        ((!query || !*query) && !valid_search_criteria(search_criteria))) {
        return failure("Invalid IMAP page arguments", CURLE_BAD_FUNCTION_ARGUMENT);
    }
    char error_buffer[CURL_ERROR_SIZE] = {0};
    const char *failed_stage = NULL;
    CURLcode code;
    CURL *curl = raw_imap_open(host, port, folder, username, password, proxy_host, proxy_port,
                               timeout_seconds, &code, &failed_stage, error_buffer);
    if (!curl) return failure(error_buffer[0] ? error_buffer : failed_stage, code);

    Buffer search_response = {0};
    int protocol_status = 0;
    failed_stage = "searching Gmail";
    if (query && *query) code = raw_literal_search(curl, query, &search_response, timeout_seconds, &protocol_status);
    else code = raw_criteria_search(curl, search_criteria, &search_response, timeout_seconds, &protocol_status);
    if (code != CURLE_OK || protocol_status != 1) {
        curl_easy_cleanup(curl);
        free(search_response.bytes);
        return failure(error_buffer[0] ? error_buffer : failed_stage, code == CURLE_OK ? CURLE_QUOTE_ERROR : code);
    }

    UIDList uids = {0};
    if (!parse_search_uids(&search_response, &uids)) {
        curl_easy_cleanup(curl);
        free(search_response.bytes);
        free(uids.values);
        return failure("Invalid Gmail SEARCH response", CURLE_WEIRD_SERVER_REPLY);
    }
    free(search_response.bytes);

    size_t offset;
    if ((size_t)(page - 1) > SIZE_MAX / (size_t)page_size) offset = SIZE_MAX;
    else offset = (size_t)(page - 1) * (size_t)page_size;
    size_t end = uids.count > offset ? uids.count - offset : 0;
    size_t start = end > (size_t)page_size ? end - (size_t)page_size : 0;
    Buffer fetch_response = {0};
    if (start < end) {
        char *command = make_fetch_command(&uids, start, end);
        if (!command) code = CURLE_OUT_OF_MEMORY;
        else {
            protocol_status = 0;
            failed_stage = "fetching Gmail message summaries";
            code = raw_command(curl, command, "A004", &fetch_response, timeout_seconds, &protocol_status);
            free(command);
            if (code == CURLE_OK && protocol_status != 1) code = CURLE_QUOTE_ERROR;
        }
    }
    curl_easy_cleanup(curl);
    if (code != CURLE_OK) {
        free(fetch_response.bytes);
        free(uids.values);
        return failure(error_buffer[0] ? error_buffer : failed_stage, code);
    }

    Buffer output = {0};
    static const unsigned char magic[] = {'G', 'R', 'P', '1'};
    int ok = buffer_append(&output, magic, sizeof(magic)) && append_u64(&output, (uint64_t)uids.count);
    for (size_t index = 0; ok && index < uids.count; ++index) ok = append_u64(&output, uids.values[index]);
    if (ok) ok = buffer_append(&output, fetch_response.bytes, fetch_response.length);
    free(fetch_response.bytes);
    free(uids.values);
    if (!ok) {
        free(output.bytes);
        return failure("Out of memory", CURLE_OUT_OF_MEMORY);
    }
    GRResult result = {output.bytes, output.length, NULL, CURLE_OK};
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
