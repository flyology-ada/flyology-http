#define _POSIX_C_SOURCE 200809L

/* OpenSSL 3 dynamic cryptography adapter for Flyology QUIC.  This adapter
 * contains no QUIC protocol state. */

#include <dlfcn.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct evp_cipher_st EVP_CIPHER;
typedef struct evp_cipher_ctx_st EVP_CIPHER_CTX;
typedef struct evp_md_st EVP_MD;
typedef struct evp_md_ctx_st EVP_MD_CTX;
typedef struct evp_pkey_st EVP_PKEY;
typedef struct evp_pkey_ctx_st EVP_PKEY_CTX;
typedef struct x509_st X509;

struct quic_crypto_module {
   void *crypto;
   unsigned long (*OpenSSL_version_num)(void);
   void (*ERR_clear_error)(void);
   unsigned long (*ERR_get_error)(void);
   void (*ERR_error_string_n)(unsigned long, char *, size_t);
   const EVP_MD *(*EVP_sha256)(void);
   int (*EVP_Digest)(const void *, size_t, unsigned char *, unsigned int *,
                     const EVP_MD *, void *);
   unsigned char *(*HMAC)(const EVP_MD *, const void *, int,
                          const unsigned char *, size_t,
                          unsigned char *, unsigned int *);
   void (*OPENSSL_cleanse)(void *, size_t);
   int (*RAND_bytes)(unsigned char *, int);
   int (*OBJ_sn2nid)(const char *);
   EVP_PKEY *(*EVP_PKEY_new_raw_private_key)
     (int, void *, const unsigned char *, size_t);
   EVP_PKEY *(*EVP_PKEY_new_raw_public_key)
     (int, void *, const unsigned char *, size_t);
   int (*EVP_PKEY_get_raw_public_key)(const EVP_PKEY *, unsigned char *,
                                      size_t *);
   void (*EVP_PKEY_free)(EVP_PKEY *);
   EVP_PKEY_CTX *(*EVP_PKEY_CTX_new)(EVP_PKEY *, void *);
   void (*EVP_PKEY_CTX_free)(EVP_PKEY_CTX *);
   int (*EVP_PKEY_derive_init)(EVP_PKEY_CTX *);
   int (*EVP_PKEY_derive_set_peer)(EVP_PKEY_CTX *, const EVP_PKEY *);
   int (*EVP_PKEY_derive)(EVP_PKEY_CTX *, unsigned char *, size_t *);
   EVP_MD_CTX *(*EVP_MD_CTX_new)(void);
   void (*EVP_MD_CTX_free)(EVP_MD_CTX *);
   int (*EVP_DigestSignInit)
     (EVP_MD_CTX *, EVP_PKEY_CTX **, const EVP_MD *, void *, EVP_PKEY *);
   int (*EVP_DigestSign)
     (EVP_MD_CTX *, unsigned char *, size_t *, const unsigned char *, size_t);
   int (*EVP_DigestVerifyInit)
     (EVP_MD_CTX *, EVP_PKEY_CTX **, const EVP_MD *, void *, EVP_PKEY *);
   int (*EVP_DigestVerify)
     (EVP_MD_CTX *, const unsigned char *, size_t,
      const unsigned char *, size_t);
   X509 *(*d2i_X509)(X509 **, const unsigned char **, long);
   void (*X509_free)(X509 *);
   EVP_PKEY *(*X509_get_pubkey)(X509 *);
   const EVP_CIPHER *(*EVP_aes_128_ecb)(void);
   const EVP_CIPHER *(*EVP_aes_128_gcm)(void);
   EVP_CIPHER_CTX *(*EVP_CIPHER_CTX_new)(void);
   void (*EVP_CIPHER_CTX_free)(EVP_CIPHER_CTX *);
   int (*EVP_CIPHER_CTX_ctrl)(EVP_CIPHER_CTX *, int, int, void *);
   int (*EVP_CIPHER_CTX_set_padding)(EVP_CIPHER_CTX *, int);
   int (*EVP_EncryptInit_ex)(EVP_CIPHER_CTX *, const EVP_CIPHER *, void *,
                             const unsigned char *, const unsigned char *);
   int (*EVP_EncryptUpdate)(EVP_CIPHER_CTX *, unsigned char *, int *,
                            const unsigned char *, int);
   int (*EVP_EncryptFinal_ex)(EVP_CIPHER_CTX *, unsigned char *, int *);
   int (*EVP_DecryptInit_ex)(EVP_CIPHER_CTX *, const EVP_CIPHER *, void *,
                             const unsigned char *, const unsigned char *);
   int (*EVP_DecryptUpdate)(EVP_CIPHER_CTX *, unsigned char *, int *,
                            const unsigned char *, int);
   int (*EVP_DecryptFinal_ex)(EVP_CIPHER_CTX *, unsigned char *, int *);
};

static void set_error(char *buffer, size_t size, const char *message)
{
   if (buffer != NULL && size != 0)
      snprintf(buffer, size, "%s", message != NULL ? message : "unknown error");
}

static void loader_error(char *buffer, size_t size, const char *name)
{
   const char *detail = dlerror();
   if (buffer != NULL && size != 0)
      snprintf(buffer, size, "%s: %s", name,
               detail != NULL ? detail : "dynamic loader failure");
}

static int make_path(char *out, size_t size, const char *directory,
                     const char *name)
{
   int count = directory == NULL || directory[0] == '\0'
     ? snprintf(out, size, "%s", name)
     : snprintf(out, size, "%s/%s", directory, name);
   return count >= 0 && (size_t)count < size;
}

static void *required_symbol(void *handle, const char *name,
                             char *error, size_t error_size)
{
   void *symbol;
   dlerror();
   symbol = dlsym(handle, name);
   if (symbol == NULL) loader_error(error, error_size, name);
   return symbol;
}

#define LOAD(module, member) do {                                               \
   void *symbol = required_symbol((module)->crypto, #member, error, error_size); \
   if (symbol == NULL) goto fail;                                                \
   _Static_assert(sizeof((module)->member) == sizeof(symbol),                    \
                  "function and data pointers must have equal size");           \
   memcpy(&(module)->member, &symbol, sizeof((module)->member));                  \
} while (0)

static void release_module(struct quic_crypto_module *module)
{
   if (module == NULL) return;
   if (module->crypto != NULL) dlclose(module->crypto);
   free(module);
}

static struct quic_crypto_module *load_from_directory
  (const char *directory, char *error, size_t error_size)
{
   struct quic_crypto_module *module = NULL;
   char path[1024];
#if defined(__APPLE__)
   const char *name = "libcrypto.3.dylib";
#else
   const char *name = "libcrypto.so.3";
#endif

   if (!make_path(path, sizeof path, directory, name)) {
      set_error(error, error_size, "OpenSSL library directory is too long");
      return NULL;
   }
   module = calloc(1, sizeof *module);
   if (module == NULL) {
      set_error(error, error_size, "cannot allocate OpenSSL module table");
      return NULL;
   }
   module->crypto = dlopen(path, RTLD_NOW | RTLD_LOCAL);
   if (module->crypto == NULL) {
      loader_error(error, error_size, path);
      goto fail;
   }

   LOAD(module, OpenSSL_version_num);
   if ((module->OpenSSL_version_num() >> 28) != 3) {
      set_error(error, error_size, "QUIC requires OpenSSL 3.x");
      goto fail;
   }
   LOAD(module, ERR_clear_error);
   LOAD(module, ERR_get_error);
   LOAD(module, ERR_error_string_n);
   LOAD(module, EVP_sha256);
   LOAD(module, EVP_Digest);
   LOAD(module, HMAC);
   LOAD(module, OPENSSL_cleanse);
   LOAD(module, RAND_bytes);
   LOAD(module, OBJ_sn2nid);
   LOAD(module, EVP_PKEY_new_raw_private_key);
   LOAD(module, EVP_PKEY_new_raw_public_key);
   LOAD(module, EVP_PKEY_get_raw_public_key);
   LOAD(module, EVP_PKEY_free);
   LOAD(module, EVP_PKEY_CTX_new);
   LOAD(module, EVP_PKEY_CTX_free);
   LOAD(module, EVP_PKEY_derive_init);
   LOAD(module, EVP_PKEY_derive_set_peer);
   LOAD(module, EVP_PKEY_derive);
   LOAD(module, EVP_MD_CTX_new);
   LOAD(module, EVP_MD_CTX_free);
   LOAD(module, EVP_DigestSignInit);
   LOAD(module, EVP_DigestSign);
   LOAD(module, EVP_DigestVerifyInit);
   LOAD(module, EVP_DigestVerify);
   LOAD(module, d2i_X509);
   LOAD(module, X509_free);
   LOAD(module, X509_get_pubkey);
   LOAD(module, EVP_aes_128_ecb);
   LOAD(module, EVP_aes_128_gcm);
   LOAD(module, EVP_CIPHER_CTX_new);
   LOAD(module, EVP_CIPHER_CTX_free);
   LOAD(module, EVP_CIPHER_CTX_ctrl);
   LOAD(module, EVP_CIPHER_CTX_set_padding);
   LOAD(module, EVP_EncryptInit_ex);
   LOAD(module, EVP_EncryptUpdate);
   LOAD(module, EVP_EncryptFinal_ex);
   LOAD(module, EVP_DecryptInit_ex);
   LOAD(module, EVP_DecryptUpdate);
   LOAD(module, EVP_DecryptFinal_ex);
   return module;

fail:
   release_module(module);
   return NULL;
}

static struct quic_crypto_module *load_module
  (const char *directory, char *error, size_t error_size)
{
   struct quic_crypto_module *module;
   if (directory != NULL && directory[0] != '\0')
      return load_from_directory(directory, error, error_size);
#if defined(__APPLE__)
   static const char *directories[] = {
      "/opt/homebrew/opt/openssl@3/lib",
      "/usr/local/opt/openssl@3/lib",
      ""
   };
#else
   static const char *directories[] = { "" };
#endif
   for (size_t index = 0;
        index < sizeof directories / sizeof directories[0]; ++index) {
      module = load_from_directory(directories[index], error, error_size);
      if (module != NULL) return module;
   }
   return NULL;
}

static void provider_error(struct quic_crypto_module *module,
                           char *buffer, size_t size, const char *fallback)
{
   unsigned long code = module->ERR_get_error();
   if (code != 0) module->ERR_error_string_n(code, buffer, size);
   else set_error(buffer, size, fallback);
}

#define SHA256_LENGTH 32

static int hmac_sha256(struct quic_crypto_module *module,
                       const unsigned char *key, size_t key_length,
                       const unsigned char *data, size_t data_length,
                       unsigned char output[SHA256_LENGTH])
{
   unsigned int output_length = 0;
   if (key_length > INT32_MAX) return 0;
   module->ERR_clear_error();
   return module->HMAC(module->EVP_sha256(), key, (int)key_length,
                       data, data_length, output, &output_length) != NULL &&
          output_length == SHA256_LENGTH;
}

static int hkdf_expand_label
  (struct quic_crypto_module *module,
   const unsigned char secret[SHA256_LENGTH], const char *label,
   unsigned char *output, size_t output_length)
{
   static const unsigned char prefix[] = "tls13 ";
   unsigned char input[256];
   unsigned char digest[SHA256_LENGTH];
   size_t label_length = strlen(label);
   size_t full_label_length = sizeof prefix - 1 + label_length;
   size_t cursor = 0;
   int success = 0;

   if (output_length > SHA256_LENGTH || full_label_length > 255 ||
       2 + 1 + full_label_length + 1 + 1 > sizeof input)
      return 0;
   input[cursor++] = (unsigned char)(output_length >> 8);
   input[cursor++] = (unsigned char)output_length;
   input[cursor++] = (unsigned char)full_label_length;
   memcpy(input + cursor, prefix, sizeof prefix - 1);
   cursor += sizeof prefix - 1;
   memcpy(input + cursor, label, label_length);
   cursor += label_length;
   input[cursor++] = 0;
   input[cursor++] = 1;
   if (hmac_sha256(module, secret, SHA256_LENGTH, input, cursor, digest)) {
      memcpy(output, digest, output_length);
      success = 1;
   }
   module->OPENSSL_cleanse(digest, sizeof digest);
   module->OPENSSL_cleanse(input, sizeof input);
   return success;
}

static int initial_direction
  (struct quic_crypto_module *module,
   const unsigned char initial_secret[SHA256_LENGTH], const char *direction,
   unsigned char secret[SHA256_LENGTH], unsigned char key[16],
   unsigned char iv[12], unsigned char hp[16])
{
   return hkdf_expand_label(module, initial_secret, direction,
                            secret, SHA256_LENGTH) &&
          hkdf_expand_label(module, secret, "quic key", key, 16) &&
          hkdf_expand_label(module, secret, "quic iv", iv, 12) &&
          hkdf_expand_label(module, secret, "quic hp", hp, 16);
}

void *flyology_quic_openssl_create(const char *directory,
                                    char *error, size_t error_size)
{
   return load_module(directory, error, error_size);
}

void flyology_quic_openssl_release(void *handle)
{
   release_module(handle);
}

int flyology_quic_openssl_initial_keys
  (void *handle, const unsigned char *connection_id, size_t connection_id_length,
   unsigned char client_secret[32], unsigned char client_key[16],
   unsigned char client_iv[12], unsigned char client_hp[16],
   unsigned char server_secret[32], unsigned char server_key[16],
   unsigned char server_iv[12], unsigned char server_hp[16],
   char *error, size_t error_size)
{
   static const unsigned char initial_salt[20] = {
      0x38, 0x76, 0x2c, 0xf7, 0xf5, 0x59, 0x34, 0xb3, 0x4d, 0x17,
      0x9a, 0xe6, 0xa4, 0xc8, 0x0c, 0xad, 0xcc, 0xbb, 0x7f, 0x0a
   };
   struct quic_crypto_module *module = handle;
   unsigned char initial_secret[SHA256_LENGTH];
   int success = 0;

   if (module == NULL || (connection_id_length != 0 && connection_id == NULL) ||
       client_secret == NULL || client_key == NULL || client_iv == NULL ||
       client_hp == NULL || server_secret == NULL || server_key == NULL ||
       server_iv == NULL || server_hp == NULL) {
      set_error(error, error_size, "invalid QUIC initial-key arguments");
      return -1;
   }
   if (!hmac_sha256(module, initial_salt, sizeof initial_salt,
                    connection_id, connection_id_length, initial_secret) ||
       !initial_direction(module, initial_secret, "client in",
                          client_secret, client_key, client_iv, client_hp) ||
       !initial_direction(module, initial_secret, "server in",
                          server_secret, server_key, server_iv, server_hp)) {
      provider_error(module, error, error_size,
                     "OpenSSL QUIC initial-key derivation failed");
      goto done;
   }
   success = 1;
done:
   module->OPENSSL_cleanse(initial_secret, sizeof initial_secret);
   return success ? 0 : -1;
}

#define EVP_CTRL_AEAD_SET_IVLEN 0x9
#define EVP_CTRL_AEAD_GET_TAG 0x10
#define EVP_CTRL_AEAD_SET_TAG 0x11

int flyology_quic_openssl_protect
  (void *handle, const unsigned char key[16], const unsigned char nonce[12],
   const unsigned char *header, size_t header_length,
   const unsigned char *plaintext, size_t plaintext_length,
   unsigned char *ciphertext, size_t ciphertext_length,
   char *error, size_t error_size)
{
   struct quic_crypto_module *module = handle;
   EVP_CIPHER_CTX *context = NULL;
   int aad_produced = 0;
   int produced = 0;
   int final_length = 0;
   int success = 0;

   if (module == NULL || key == NULL || nonce == NULL || ciphertext == NULL ||
       plaintext_length > INT32_MAX || header_length > INT32_MAX ||
       plaintext_length > SIZE_MAX - 16 ||
       ciphertext_length != plaintext_length + 16 ||
       (header_length != 0 && header == NULL) ||
       (plaintext_length != 0 && plaintext == NULL)) {
      set_error(error, error_size, "invalid QUIC payload-protection arguments");
      return -1;
   }
   module->ERR_clear_error();
   context = module->EVP_CIPHER_CTX_new();
   if (context == NULL ||
       module->EVP_EncryptInit_ex(context, module->EVP_aes_128_gcm(), NULL,
                                  NULL, NULL) != 1 ||
       module->EVP_CIPHER_CTX_ctrl(context, EVP_CTRL_AEAD_SET_IVLEN,
                                   12, NULL) != 1 ||
       module->EVP_EncryptInit_ex(context, NULL, NULL, key, nonce) != 1 ||
       (header_length != 0 &&
        module->EVP_EncryptUpdate(context, NULL, &aad_produced, header,
                                  (int)header_length) != 1) ||
       (plaintext_length != 0 &&
        module->EVP_EncryptUpdate(context, ciphertext, &produced, plaintext,
                                  (int)plaintext_length) != 1) ||
       module->EVP_EncryptFinal_ex(context, ciphertext + produced,
                                   &final_length) != 1 ||
       (size_t)(produced + final_length) != plaintext_length ||
       module->EVP_CIPHER_CTX_ctrl(context, EVP_CTRL_AEAD_GET_TAG, 16,
                                   ciphertext + plaintext_length) != 1) {
      provider_error(module, error, error_size,
                     "OpenSSL QUIC payload protection failed");
      goto done;
   }
   success = 1;
done:
   if (context != NULL) module->EVP_CIPHER_CTX_free(context);
   return success ? 0 : -1;
}

int flyology_quic_openssl_unprotect
  (void *handle, const unsigned char key[16], const unsigned char nonce[12],
   const unsigned char *header, size_t header_length,
   const unsigned char *ciphertext, size_t ciphertext_length,
   unsigned char *plaintext, size_t plaintext_length,
   char *error, size_t error_size)
{
   struct quic_crypto_module *module = handle;
   EVP_CIPHER_CTX *context = NULL;
   unsigned char empty_output[1];
   unsigned char *output;
   size_t encrypted_length;
   int aad_produced = 0;
   int produced = 0;
   int final_length = 0;
   int final_status;
   int status = -1;

   if (module == NULL || key == NULL || nonce == NULL ||
       ciphertext == NULL || ciphertext_length < 16 ||
       ciphertext_length - 16 > INT32_MAX || header_length > INT32_MAX ||
       plaintext_length != ciphertext_length - 16 ||
       (header_length != 0 && header == NULL) ||
       (plaintext_length != 0 && plaintext == NULL)) {
      set_error(error, error_size,
                "invalid QUIC payload-unprotection arguments");
      return -1;
   }
   encrypted_length = ciphertext_length - 16;
   output = plaintext_length == 0 ? empty_output : plaintext;
   module->ERR_clear_error();
   context = module->EVP_CIPHER_CTX_new();
   if (context == NULL ||
       module->EVP_DecryptInit_ex(context, module->EVP_aes_128_gcm(), NULL,
                                  NULL, NULL) != 1 ||
       module->EVP_CIPHER_CTX_ctrl(context, EVP_CTRL_AEAD_SET_IVLEN,
                                   12, NULL) != 1 ||
       module->EVP_DecryptInit_ex(context, NULL, NULL, key, nonce) != 1 ||
       (header_length != 0 &&
        module->EVP_DecryptUpdate(context, NULL, &aad_produced, header,
                                  (int)header_length) != 1) ||
       (encrypted_length != 0 &&
        module->EVP_DecryptUpdate(context, output, &produced, ciphertext,
                                  (int)encrypted_length) != 1) ||
       module->EVP_CIPHER_CTX_ctrl
         (context, EVP_CTRL_AEAD_SET_TAG, 16,
          (void *)(ciphertext + encrypted_length)) != 1) {
      provider_error(module, error, error_size,
                     "OpenSSL QUIC payload unprotection failed");
      goto done;
   }

   final_status = module->EVP_DecryptFinal_ex
     (context, output + produced, &final_length);
   if (final_status == 0) {
      status = 1;
      goto done;
   }
   if (final_status != 1) {
      provider_error(module, error, error_size,
                     "OpenSSL QUIC payload unprotection finalization failed");
      goto done;
   }
   if ((size_t)(produced + final_length) != plaintext_length) {
      if (error != NULL && error_size != 0)
         snprintf(error, error_size,
                  "OpenSSL QUIC payload unprotection length mismatch: "
                  "produced=%d final=%d expected=%zu",
                  produced, final_length, plaintext_length);
      goto done;
   }
   status = 0;
done:
   if (status != 0 && plaintext != NULL)
      module->OPENSSL_cleanse(plaintext, plaintext_length);
   if (context != NULL) module->EVP_CIPHER_CTX_free(context);
   return status;
}

int flyology_quic_openssl_header_mask
  (void *handle, const unsigned char key[16],
   const unsigned char sample[16], unsigned char mask[5],
   char *error, size_t error_size)
{
   struct quic_crypto_module *module = handle;
   EVP_CIPHER_CTX *context = NULL;
   unsigned char block[16];
   int produced = 0;
   int final_length = 0;
   int success = 0;

   memset(block, 0, sizeof block);
   if (module == NULL || key == NULL || sample == NULL || mask == NULL) {
      set_error(error, error_size, "invalid QUIC header-mask arguments");
      return -1;
   }
   module->ERR_clear_error();
   context = module->EVP_CIPHER_CTX_new();
   if (context == NULL ||
       module->EVP_EncryptInit_ex(context, module->EVP_aes_128_ecb(), NULL,
                                  key, NULL) != 1 ||
       module->EVP_CIPHER_CTX_set_padding(context, 0) != 1 ||
       module->EVP_EncryptUpdate(context, block, &produced, sample, 16) != 1 ||
       module->EVP_EncryptFinal_ex(context, block + produced,
                                   &final_length) != 1 ||
       produced + final_length != 16) {
      provider_error(module, error, error_size,
                     "OpenSSL QUIC header protection failed");
      goto done;
   }
   memcpy(mask, block, 5);
   success = 1;
done:
   module->OPENSSL_cleanse(block, sizeof block);
   if (context != NULL) module->EVP_CIPHER_CTX_free(context);
   return success ? 0 : -1;
}

int flyology_quic_openssl_random
  (void *handle, unsigned char *output, size_t output_length,
   char *error, size_t error_size)
{
   struct quic_crypto_module *module = handle;
   if (module == NULL || (output_length != 0 && output == NULL) ||
       output_length > INT32_MAX) {
      set_error(error, error_size, "invalid QUIC random arguments");
      return -1;
   }
   module->ERR_clear_error();
   if (output_length != 0 &&
       module->RAND_bytes(output, (int)output_length) != 1) {
      provider_error(module, error, error_size, "OpenSSL randomness failed");
      return -1;
   }
   return 0;
}

int flyology_quic_openssl_sha256
  (void *handle, const unsigned char *data, size_t data_length,
   unsigned char output[32], char *error, size_t error_size)
{
   struct quic_crypto_module *module = handle;
   unsigned int output_length = 0;
   if (module == NULL || output == NULL ||
       (data_length != 0 && data == NULL)) {
      set_error(error, error_size, "invalid QUIC SHA-256 arguments");
      return -1;
   }
   module->ERR_clear_error();
   if (module->EVP_Digest(data, data_length, output, &output_length,
                          module->EVP_sha256(), NULL) != 1 ||
       output_length != 32) {
      provider_error(module, error, error_size, "OpenSSL SHA-256 failed");
      return -1;
   }
   return 0;
}

int flyology_quic_openssl_hmac_sha256
  (void *handle, const unsigned char *key, size_t key_length,
   const unsigned char *data, size_t data_length, unsigned char output[32],
   char *error, size_t error_size)
{
   struct quic_crypto_module *module = handle;
   if (module == NULL || output == NULL ||
       (key_length != 0 && key == NULL) ||
       (data_length != 0 && data == NULL)) {
      set_error(error, error_size, "invalid QUIC HMAC arguments");
      return -1;
   }
   if (!hmac_sha256(module, key, key_length, data, data_length, output)) {
      module->OPENSSL_cleanse(output, 32);
      provider_error(module, error, error_size, "OpenSSL HMAC-SHA256 failed");
      return -1;
   }
   return 0;
}

int flyology_quic_openssl_x25519_public
  (void *handle, const unsigned char private_key[32],
   unsigned char public_key[32], char *error, size_t error_size)
{
   struct quic_crypto_module *module = handle;
   EVP_PKEY *key = NULL;
   size_t public_length = 32;
   int nid;
   int success = 0;
   if (module == NULL || private_key == NULL || public_key == NULL) {
      set_error(error, error_size, "invalid X25519 public-key arguments");
      return -1;
   }
   module->ERR_clear_error();
   nid = module->OBJ_sn2nid("X25519");
   if (nid == 0) {
      provider_error(module, error, error_size,
                     "OpenSSL does not provide X25519");
      goto done;
   }
   key = module->EVP_PKEY_new_raw_private_key
     (nid, NULL, private_key, 32);
   if (key == NULL ||
       module->EVP_PKEY_get_raw_public_key
         (key, public_key, &public_length) != 1 || public_length != 32) {
      provider_error(module, error, error_size,
                     "OpenSSL X25519 public-key derivation failed");
      goto done;
   }
   success = 1;
done:
   if (key != NULL) module->EVP_PKEY_free(key);
   if (!success) module->OPENSSL_cleanse(public_key, 32);
   return success ? 0 : -1;
}

int flyology_quic_openssl_x25519_shared
  (void *handle, const unsigned char private_key[32],
   const unsigned char peer_public_key[32], unsigned char shared_secret[32],
   char *error, size_t error_size)
{
   struct quic_crypto_module *module = handle;
   EVP_PKEY *local = NULL;
   EVP_PKEY *peer = NULL;
   EVP_PKEY_CTX *context = NULL;
   size_t shared_length = 32;
   int nid;
   int success = 0;
   if (module == NULL || private_key == NULL || peer_public_key == NULL ||
       shared_secret == NULL) {
      set_error(error, error_size, "invalid X25519 shared-secret arguments");
      return -1;
   }
   module->ERR_clear_error();
   nid = module->OBJ_sn2nid("X25519");
   if (nid == 0) {
      provider_error(module, error, error_size,
                     "OpenSSL does not provide X25519");
      goto done;
   }
   local = module->EVP_PKEY_new_raw_private_key
     (nid, NULL, private_key, 32);
   peer = module->EVP_PKEY_new_raw_public_key
     (nid, NULL, peer_public_key, 32);
   if (local == NULL || peer == NULL ||
       (context = module->EVP_PKEY_CTX_new(local, NULL)) == NULL ||
       module->EVP_PKEY_derive_init(context) != 1 ||
       module->EVP_PKEY_derive_set_peer(context, peer) != 1 ||
       module->EVP_PKEY_derive
         (context, shared_secret, &shared_length) != 1 || shared_length != 32) {
      provider_error(module, error, error_size,
                     "OpenSSL X25519 shared-secret derivation failed");
      goto done;
   }
   success = 1;
done:
   if (context != NULL) module->EVP_PKEY_CTX_free(context);
   if (peer != NULL) module->EVP_PKEY_free(peer);
   if (local != NULL) module->EVP_PKEY_free(local);
   if (!success) module->OPENSSL_cleanse(shared_secret, 32);
   return success ? 0 : -1;
}

int flyology_quic_openssl_ed25519_public
  (void *handle, const unsigned char private_key[32],
   unsigned char public_key[32], char *error, size_t error_size)
{
   struct quic_crypto_module *module = handle;
   EVP_PKEY *key = NULL;
   size_t public_length = 32;
   int nid;
   int success = 0;
   if (module == NULL || private_key == NULL || public_key == NULL) {
      set_error(error, error_size, "invalid Ed25519 public-key arguments");
      return -1;
   }
   module->ERR_clear_error();
   nid = module->OBJ_sn2nid("ED25519");
   if (nid == 0) {
      provider_error(module, error, error_size,
                     "OpenSSL does not provide Ed25519");
      goto done;
   }
   key = module->EVP_PKEY_new_raw_private_key
     (nid, NULL, private_key, 32);
   if (key == NULL ||
       module->EVP_PKEY_get_raw_public_key
         (key, public_key, &public_length) != 1 || public_length != 32) {
      provider_error(module, error, error_size,
                     "OpenSSL Ed25519 public-key derivation failed");
      goto done;
   }
   success = 1;
done:
   if (key != NULL) module->EVP_PKEY_free(key);
   if (!success) module->OPENSSL_cleanse(public_key, 32);
   return success ? 0 : -1;
}

int flyology_quic_openssl_ed25519_sign
  (void *handle, const unsigned char private_key[32],
   const unsigned char *message, size_t message_length,
   unsigned char signature[64], char *error, size_t error_size)
{
   static const unsigned char empty = 0;
   struct quic_crypto_module *module = handle;
   EVP_PKEY *key = NULL;
   EVP_MD_CTX *context = NULL;
   size_t signature_length = 64;
   int nid;
   int success = 0;
   if (module == NULL || private_key == NULL || signature == NULL ||
       (message_length != 0 && message == NULL)) {
      set_error(error, error_size, "invalid Ed25519 signing arguments");
      return -1;
   }
   module->ERR_clear_error();
   nid = module->OBJ_sn2nid("ED25519");
   if (nid == 0 ||
       (key = module->EVP_PKEY_new_raw_private_key
          (nid, NULL, private_key, 32)) == NULL ||
       (context = module->EVP_MD_CTX_new()) == NULL ||
       module->EVP_DigestSignInit(context, NULL, NULL, NULL, key) != 1 ||
       module->EVP_DigestSign
         (context, signature, &signature_length,
          message_length == 0 ? &empty : message, message_length) != 1 ||
       signature_length != 64) {
      provider_error(module, error, error_size, "OpenSSL Ed25519 signing failed");
      goto done;
   }
   success = 1;
done:
   if (context != NULL) module->EVP_MD_CTX_free(context);
   if (key != NULL) module->EVP_PKEY_free(key);
   if (!success) module->OPENSSL_cleanse(signature, 64);
   return success ? 0 : -1;
}

static int verify_ed25519
  (struct quic_crypto_module *module, EVP_PKEY *key,
   const unsigned char *message, size_t message_length,
   const unsigned char signature[64])
{
   static const unsigned char empty = 0;
   EVP_MD_CTX *context = NULL;
   int status;
   context = module->EVP_MD_CTX_new();
   if (context == NULL ||
       module->EVP_DigestVerifyInit(context, NULL, NULL, NULL, key) != 1) {
      if (context != NULL) module->EVP_MD_CTX_free(context);
      return -1;
   }
   status = module->EVP_DigestVerify
     (context, signature, 64, message_length == 0 ? &empty : message,
      message_length);
   module->EVP_MD_CTX_free(context);
   return status == 1 ? 0 : status == 0 ? 1 : -1;
}

int flyology_quic_openssl_ed25519_verify
  (void *handle, const unsigned char public_key[32],
   const unsigned char *message, size_t message_length,
   const unsigned char signature[64], char *error, size_t error_size)
{
   struct quic_crypto_module *module = handle;
   EVP_PKEY *key = NULL;
   int nid;
   int status;
   if (module == NULL || public_key == NULL || signature == NULL ||
       (message_length != 0 && message == NULL)) {
      set_error(error, error_size, "invalid Ed25519 verification arguments");
      return -1;
   }
   module->ERR_clear_error();
   nid = module->OBJ_sn2nid("ED25519");
   key = nid == 0 ? NULL : module->EVP_PKEY_new_raw_public_key
     (nid, NULL, public_key, 32);
   if (key == NULL) {
      provider_error(module, error, error_size,
                     "OpenSSL Ed25519 public key failed");
      return -1;
   }
   status = verify_ed25519
     (module, key, message, message_length, signature);
   module->EVP_PKEY_free(key);
   if (status < 0)
      provider_error(module, error, error_size,
                     "OpenSSL Ed25519 verification failed");
   return status;
}

int flyology_quic_openssl_ed25519_verify_certificate
  (void *handle, const unsigned char *certificate, size_t certificate_length,
   const unsigned char *message, size_t message_length,
   const unsigned char signature[64], char *error, size_t error_size)
{
   struct quic_crypto_module *module = handle;
   const unsigned char *cursor = certificate;
   X509 *parsed = NULL;
   EVP_PKEY *key = NULL;
   int status;
   if (module == NULL || certificate == NULL || certificate_length == 0 ||
       certificate_length > LONG_MAX || signature == NULL ||
       (message_length != 0 && message == NULL)) {
      set_error(error, error_size,
                "invalid Ed25519 certificate verification arguments");
      return -1;
   }
   module->ERR_clear_error();
   parsed = module->d2i_X509(NULL, &cursor, (long)certificate_length);
   if (parsed == NULL || cursor != certificate + certificate_length) {
      if (parsed != NULL) module->X509_free(parsed);
      module->ERR_clear_error();
      return 1;
   }
   key = module->X509_get_pubkey(parsed);
   if (key == NULL) {
      module->X509_free(parsed);
      module->ERR_clear_error();
      return 1;
   }
   status = verify_ed25519
     (module, key, message, message_length, signature);
   module->EVP_PKEY_free(key);
   module->X509_free(parsed);
   if (status < 0) {
      module->ERR_clear_error();
      return 1;
   }
   return status;
}
