/*
 * xsp_loader — extensão PHP que registra o stream wrapper "xsp://"
 * Decifra arquivos .php.enc (AES-256-GCM) em memória, com chave fornecida
 * via xsp_unlock($hexkey).
 *
 * Layout do arquivo cifrado (.php.enc):
 *   [magic "XSP1" 4B] [iv 12B] [ciphertext N B] [tag 16B]
 *
 * O wrapper "xsp://" mapeia o caminho lógico para o real adicionando ".enc".
 *   Ex: include "xsp:///var/www/html/dashboard.php"
 *       lê /var/www/html/dashboard.php.enc, decifra e retorna o conteúdo.
 */

#ifdef HAVE_CONFIG_H
# include "config.h"
#endif

#include "php.h"
#include "php_ini.h"
#include "ext/standard/info.h"
#include "ext/standard/php_string.h"
#include "Zend/zend_API.h"
#include "Zend/zend_exceptions.h"
#include "php_xsp_loader.h"
#include "php_streams.h"

#include <string.h>
#include <openssl/evp.h>
#include <openssl/err.h>

#ifdef HAVE_SYS_PTRACE_H
# include <sys/ptrace.h>
#endif
#include <sys/types.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>

#define XSP_MAGIC      "XSP1"
#define XSP_MAGIC_LEN  4
#define XSP_IV_LEN     12
#define XSP_TAG_LEN    16
#define XSP_KEY_LEN    32

static unsigned char xsp_master_key[XSP_KEY_LEN];
static int xsp_unlocked = 0;

/* ---------- Anti-debug ---------- */

static void xsp_anti_debug(void) {
#if defined(__linux__) && defined(HAVE_SYS_PTRACE_H)
    if (ptrace(PTRACE_TRACEME, 0, 1, 0) < 0) {
        /* já tracado — sai */
        _exit(99);
    }
#endif
}

/* ---------- helpers ---------- */

static int hex2bin32(const char *hex, size_t hex_len, unsigned char out[XSP_KEY_LEN]) {
    if (hex_len != 64) return 0;
    for (size_t i = 0; i < XSP_KEY_LEN; i++) {
        unsigned int b;
        if (sscanf(hex + 2*i, "%2x", &b) != 1) return 0;
        out[i] = (unsigned char)b;
    }
    return 1;
}

static int xsp_decrypt_file(const char *path, unsigned char **out_buf, size_t *out_len) {
    FILE *fp = fopen(path, "rb");
    if (!fp) return 0;

    unsigned char magic[XSP_MAGIC_LEN];
    unsigned char iv[XSP_IV_LEN];
    unsigned char tag[XSP_TAG_LEN];

    if (fread(magic, 1, XSP_MAGIC_LEN, fp) != XSP_MAGIC_LEN ||
        memcmp(magic, XSP_MAGIC, XSP_MAGIC_LEN) != 0) {
        fclose(fp); return 0;
    }
    if (fread(iv, 1, XSP_IV_LEN, fp) != XSP_IV_LEN) { fclose(fp); return 0; }

    if (fseek(fp, 0, SEEK_END) != 0) { fclose(fp); return 0; }
    long fsize = ftell(fp);
    if (fsize < (long)(XSP_MAGIC_LEN + XSP_IV_LEN + XSP_TAG_LEN)) { fclose(fp); return 0; }
    long csize = fsize - XSP_MAGIC_LEN - XSP_IV_LEN - XSP_TAG_LEN;
    if (fseek(fp, XSP_MAGIC_LEN + XSP_IV_LEN, SEEK_SET) != 0) { fclose(fp); return 0; }

    unsigned char *cipher = (unsigned char *)emalloc(csize > 0 ? csize : 1);
    unsigned char *plain  = (unsigned char *)emalloc(csize > 0 ? csize + 16 : 16);
    if (csize > 0 && fread(cipher, 1, csize, fp) != (size_t)csize) {
        efree(cipher); efree(plain); fclose(fp); return 0;
    }
    if (fread(tag, 1, XSP_TAG_LEN, fp) != XSP_TAG_LEN) {
        efree(cipher); efree(plain); fclose(fp); return 0;
    }
    fclose(fp);

    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    if (!ctx) { efree(cipher); efree(plain); return 0; }

    int outlen = 0, finlen = 0, ok = 0;
    if (EVP_DecryptInit_ex(ctx, EVP_aes_256_gcm(), NULL, xsp_master_key, iv) != 1) goto done;
    if (csize > 0 && EVP_DecryptUpdate(ctx, plain, &outlen, cipher, (int)csize) != 1) goto done;
    if (EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_TAG, XSP_TAG_LEN, tag) != 1) goto done;
    if (EVP_DecryptFinal_ex(ctx, plain + outlen, &finlen) != 1) goto done;
    ok = 1;

done:
    EVP_CIPHER_CTX_free(ctx);
    efree(cipher);
    if (!ok) { efree(plain); return 0; }
    *out_buf = plain;
    *out_len = (size_t)(outlen + finlen);
    return 1;
}

/* ---------- Stream wrapper ---------- */

static php_stream *xsp_stream_opener(
        php_stream_wrapper *wrapper, const char *path, const char *mode,
        int options, zend_string **opened_path,
        php_stream_context *context STREAMS_DC) {

    (void)wrapper; (void)mode; (void)opened_path; (void)context;

    if (!xsp_unlocked) {
        if (options & REPORT_ERRORS) {
            php_error_docref(NULL, E_WARNING, "xsp_loader: not unlocked");
        }
        return NULL;
    }

    /* path chega como "xsp:///var/www/html/dashboard.php" — strip prefix */
    const char *real = path;
    if (strncmp(path, "xsp://", 6) == 0) real = path + 6;

    /* tenta path real + ".enc" */
    size_t rl = strlen(real);
    char *p = (char *)emalloc(rl + 5);
    memcpy(p, real, rl);
    memcpy(p + rl, ".enc", 5);

    unsigned char *plain = NULL; size_t plen = 0;
    int ok = xsp_decrypt_file(p, &plain, &plen);
    efree(p);

    if (!ok) {
        if (options & REPORT_ERRORS) {
            php_error_docref(NULL, E_WARNING, "xsp_loader: decrypt failed for %s", real);
        }
        return NULL;
    }

    php_stream *s = php_stream_memory_create(TEMP_STREAM_TAKE_BUFFER);
    if (!s) { efree(plain); return NULL; }
    php_stream_write(s, (const char *)plain, plen);
    efree(plain);
    php_stream_rewind(s);
    return s;
}

static int xsp_stream_url_stat(
        php_stream_wrapper *wrapper, const char *url, int flags,
        php_stream_statbuf *ssb, php_stream_context *context) {
    (void)wrapper; (void)flags; (void)context;
    const char *real = url;
    if (strncmp(url, "xsp://", 6) == 0) real = url + 6;
    size_t rl = strlen(real);
    char *p = (char *)emalloc(rl + 5);
    memcpy(p, real, rl);
    memcpy(p + rl, ".enc", 5);
    int rv = VCWD_STAT(p, &ssb->sb);
    efree(p);
    return rv;
}

static const php_stream_wrapper_ops xsp_wops = {
    xsp_stream_opener,      /* opener */
    NULL,                   /* closer */
    NULL,                   /* stat   */
    xsp_stream_url_stat,    /* url_stat */
    NULL,                   /* dir_opener */
    "xsp",
    NULL, NULL, NULL, NULL, NULL
};

static const php_stream_wrapper xsp_wrapper = {
    (php_stream_wrapper_ops *)&xsp_wops, NULL, 0
};

/* ---------- userland funcs ---------- */

PHP_FUNCTION(xsp_unlock) {
    char *hex; size_t hex_len;
    if (zend_parse_parameters(ZEND_NUM_ARGS(), "s", &hex, &hex_len) == FAILURE) {
        RETURN_FALSE;
    }
    unsigned char k[XSP_KEY_LEN];
    if (!hex2bin32(hex, hex_len, k)) {
        RETURN_FALSE;
    }
    memcpy(xsp_master_key, k, XSP_KEY_LEN);
    /* zera buffer da chave em hex no PHP land */
    memset(hex, 0, hex_len);
    /* zera local */
    OPENSSL_cleanse(k, sizeof k);
    xsp_unlocked = 1;
    RETURN_TRUE;
}

PHP_FUNCTION(xsp_locked) {
    RETURN_BOOL(xsp_unlocked == 0);
}

PHP_FUNCTION(xsp_version) {
    RETURN_STRING(PHP_XSP_LOADER_VERSION);
}

/* arginfo */
ZEND_BEGIN_ARG_INFO_EX(arginfo_xsp_unlock, 0, 0, 1)
    ZEND_ARG_INFO(0, key_hex)
ZEND_END_ARG_INFO()

ZEND_BEGIN_ARG_INFO_EX(arginfo_xsp_void, 0, 0, 0)
ZEND_END_ARG_INFO()

static const zend_function_entry xsp_functions[] = {
    PHP_FE(xsp_unlock,  arginfo_xsp_unlock)
    PHP_FE(xsp_locked,  arginfo_xsp_void)
    PHP_FE(xsp_version, arginfo_xsp_void)
    PHP_FE_END
};

/* ---------- module ---------- */

PHP_MINIT_FUNCTION(xsp_loader) {
    xsp_anti_debug();
    php_register_url_stream_wrapper("xsp", (php_stream_wrapper *)&xsp_wrapper);
    return SUCCESS;
}

PHP_MSHUTDOWN_FUNCTION(xsp_loader) {
    php_unregister_url_stream_wrapper("xsp");
    OPENSSL_cleanse(xsp_master_key, sizeof xsp_master_key);
    xsp_unlocked = 0;
    return SUCCESS;
}

PHP_MINFO_FUNCTION(xsp_loader) {
    php_info_print_table_start();
    php_info_print_table_header(2, "xsp_loader", "enabled");
    php_info_print_table_row(2, "Version", PHP_XSP_LOADER_VERSION);
    php_info_print_table_row(2, "Stream", "xsp://");
    php_info_print_table_end();
}

zend_module_entry xsp_loader_module_entry = {
    STANDARD_MODULE_HEADER,
    "xsp_loader",
    xsp_functions,
    PHP_MINIT(xsp_loader),
    PHP_MSHUTDOWN(xsp_loader),
    NULL,
    NULL,
    PHP_MINFO(xsp_loader),
    PHP_XSP_LOADER_VERSION,
    STANDARD_MODULE_PROPERTIES
};

#ifdef COMPILE_DL_XSP_LOADER
ZEND_GET_MODULE(xsp_loader)
#endif
