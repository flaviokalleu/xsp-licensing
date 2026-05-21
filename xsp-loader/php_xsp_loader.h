/*
 * XSP Loader — encrypted PHP stream wrapper.
 */
#ifndef PHP_XSP_LOADER_H
#define PHP_XSP_LOADER_H

extern zend_module_entry xsp_loader_module_entry;
#define phpext_xsp_loader_ptr &xsp_loader_module_entry

#define PHP_XSP_LOADER_VERSION "1.0.0"

#ifdef ZTS
#include "TSRM.h"
#endif

#endif /* PHP_XSP_LOADER_H */
