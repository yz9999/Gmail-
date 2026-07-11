#ifndef GMAIL_READER_CURL_SHIM_H
#define GMAIL_READER_CURL_SHIM_H

#include <stddef.h>

typedef struct {
    unsigned char *data;
    size_t length;
    char *error;
    long status;
} GRResult;

int gr_curl_initialize(void);

GRResult gr_imap_request(
    const char *url,
    const char *username,
    const char *password,
    const char *proxy_host,
    int proxy_port,
    const char *custom_request,
    long timeout_seconds
);

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
);

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
);

GRResult gr_imap_fetch_summaries(
    const char *host,
    int port,
    const char *encoded_folder,
    const char *comma_separated_uids,
    const char *username,
    const char *password,
    const char *proxy_host,
    int proxy_port,
    long timeout_seconds
);

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
);

void gr_result_free(GRResult result);

#endif
