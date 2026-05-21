dnl config.m4 for extension xsp_loader

PHP_ARG_ENABLE([xsp_loader],
  [whether to enable xsp_loader support],
  [AS_HELP_STRING([--enable-xsp_loader],
    [Enable XSP loader (encrypted PHP stream wrapper)])],
  [no])

if test "$PHP_XSP_LOADER" != "no"; then
  AC_MSG_CHECKING([for OpenSSL])
  PKG_CHECK_MODULES([OPENSSL], [openssl], [
    AC_MSG_RESULT([yes])
  ], [
    AC_MSG_ERROR([OpenSSL not found via pkg-config])
  ])
  PHP_EVAL_INCLINE($OPENSSL_CFLAGS)
  PHP_EVAL_LIBLINE($OPENSSL_LIBS, XSP_LOADER_SHARED_LIBADD)
  PHP_SUBST(XSP_LOADER_SHARED_LIBADD)

  AC_DEFINE(HAVE_XSP_LOADER, 1, [ Have xsp_loader support ])
  PHP_NEW_EXTENSION(xsp_loader, xsp_loader.c, $ext_shared,, -DZEND_ENABLE_STATIC_TSRMLS_CACHE=1)
fi
