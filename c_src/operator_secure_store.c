/*
 * c_src/operator_secure_store.c — platform secure-store NIF: the iOS
 * Keychain, or EncryptedSharedPreferences on Android (JNI branch below).
 *
 * Wraps SecItemAdd / SecItemUpdate / SecItemCopyMatching / SecItemDelete
 * from Security.framework. Holds the OpenRouter key (Operator.KeyStore)
 * so it is encrypted at rest instead of sitting in a plain 0600 file in
 * the app's data dir. Ported from muster_app's muster_secure_store.c.
 *
 * Statically linked via mob.exs's :static_nifs entry — see
 * MobDev.StaticNifs. `-framework Security` is added from the iOS
 * build files' base frameworks lists. Operator.KeyStore only uses
 * this NIF on Android; on iOS it still keeps the file store.
 *
 * Item attributes:
 *   kSecClass                 = kSecClassGenericPassword
 *   kSecAttrService           = "com.genericjam.operator"
 *   kSecAttrAccount           = the account name passed by the caller
 *   kSecAttrAccessible        = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
 *   kSecValueData             = the value bytes
 *
 * Function surface (matches Operator.Nifs.OperatorSecureStore stubs):
 *   get(account)          → {:ok, binary} | {:ok, nil} | {:error, code}
 *   put(account, value)   → :ok | {:error, code}
 *   delete(account)       → :ok | {:error, code}
 *
 * All accounts and values are UTF-8 binaries; the NIF returns
 * {:error, {:sec, os_status_int}} on any Security.framework
 * non-success other than errSecItemNotFound (which maps to
 * {:ok, nil} on get and :ok on delete — deleting a non-existent
 * key is idempotent).
 */

#include <erl_nif.h>
#include <string.h>

/* Security.framework — Keychain APIs. CoreFoundation for CF* types. */
#if defined(__has_include)
#  if __has_include(<Security/Security.h>)
#    include <CoreFoundation/CoreFoundation.h>
#    include <Security/Security.h>
#    define OPERATOR_SECURE_STORE_HAVE_KEYCHAIN 1
#  endif
#endif

/* Android JNI — bridges to the com.genericjam.operator.OperatorSecureStore
 * Kotlin singleton, which wraps EncryptedSharedPreferences (Jetpack
 * Security) + a MasterKey held in the Android Keystore. Bootstrapped
 * from MainActivity.onCreate before the BEAM starts. */
#if defined(__ANDROID__)
#  include <jni.h>
#  define OPERATOR_SECURE_STORE_HAVE_ANDROID 1

/* mob-core exports (linked into the same liboperator.so). Same
 * shape mob_biometric_nif.zig uses. */
extern JNIEnv *get_jenv(int *attached);
extern JavaVM *g_jvm;
#endif

/* Service name — namespaces our keychain items so we can wipe them
 * on sign-out without touching other app data. Kept as a compile-
 * time constant; if it needs to change per bundle-id, wire through
 * a build-time -D. */
#define OPERATOR_SECURE_STORE_SERVICE "com.genericjam.operator"

/* ─── helpers ─────────────────────────────────────────────────── */

#ifdef OPERATOR_SECURE_STORE_HAVE_KEYCHAIN

/* Copy an Erlang binary into a fresh CFStringRef (UTF-8). Caller
 * owns the return; release with CFRelease. Returns NULL on failure. */
static CFStringRef oss_binary_to_cfstring(ErlNifBinary *bin) {
    return CFStringCreateWithBytes(
        kCFAllocatorDefault, bin->data, (CFIndex)bin->size, kCFStringEncodingUTF8, false
    );
}

/* Copy an Erlang binary into a fresh CFDataRef. Caller owns. */
static CFDataRef oss_binary_to_cfdata(ErlNifBinary *bin) {
    return CFDataCreate(kCFAllocatorDefault, bin->data, (CFIndex)bin->size);
}

/* Build the base match/identity dict — the three attributes that
 * identify our item uniquely: class + service + account. Nothing
 * else. In particular kSecAttrAccessible is NOT in here — putting
 * it in the query would make accessibility a filter, so changing
 * the constant later would orphan existing items (Apple's
 * guidance: match on class + service + account only; specify
 * kSecAttrAccessible only on the Add path). Caller owns; release
 * with CFRelease. */
static CFMutableDictionaryRef oss_base_query(CFStringRef account) {
    CFStringRef service = CFStringCreateWithCString(
        kCFAllocatorDefault, OPERATOR_SECURE_STORE_SERVICE, kCFStringEncodingUTF8
    );

    CFMutableDictionaryRef query = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks
    );

    CFDictionarySetValue(query, kSecClass, kSecClassGenericPassword);
    CFDictionarySetValue(query, kSecAttrService, service);
    CFDictionarySetValue(query, kSecAttrAccount, account);

    CFRelease(service);
    return query;
}

/* Make an Elixir {:error, {:sec, N}} tuple from an OSStatus. */
static ERL_NIF_TERM oss_sec_error(ErlNifEnv *env, OSStatus st) {
    return enif_make_tuple2(
        env, enif_make_atom(env, "error"),
        enif_make_tuple2(env, enif_make_atom(env, "sec"), enif_make_int(env, (int)st))
    );
}

#endif /* OPERATOR_SECURE_STORE_HAVE_KEYCHAIN */

/* ─── Android JNI bridge ──────────────────────────────────────── */

#ifdef OPERATOR_SECURE_STORE_HAVE_ANDROID

/* Bridge-class method-id cache. Populated at app startup from
 * `Java_com_genericjam_operator_OperatorSecureStore_nativeRegister`
 * — OperatorSecureStore.kt's init() calls it while the app class
 * loader is still on the stack. FindClass from a BEAM scheduler
 * thread would walk the system class loader and fail to see the
 * app's own classes, so lazy lookup from Elixir is a no-go. */
static jclass g_oss_cls = NULL;
static jmethodID g_oss_get = NULL;
static jmethodID g_oss_put = NULL;
static jmethodID g_oss_delete = NULL;

/* Read-only cache check. Returns 0 if the class + method IDs are
 * populated, -1 otherwise (means MainActivity.onCreate hasn't run
 * or OperatorSecureStore.init(context) wasn't called before the
 * first NIF call — a deploy-time bug). */
static int oss_android_init(JNIEnv *jenv) {
    (void)jenv;

    if (g_oss_cls != NULL && g_oss_get != NULL && g_oss_put != NULL && g_oss_delete != NULL) {
        return 0;
    }
    return -1;
}

/* Called from Kotlin at app startup — the JNIEnv here has the app
 * class loader on its stack, so GetStaticMethodID resolves against
 * the app's own OperatorSecureStore. NewGlobalRef pins the class
 * across scheduler threads. Safe to call multiple times (idempotent). */
JNIEXPORT void JNICALL
Java_com_genericjam_operator_OperatorSecureStore_nativeRegister(JNIEnv *jenv, jclass cls) {
    if (g_oss_cls != NULL)
        return;

    g_oss_cls = (jclass)(*jenv)->NewGlobalRef(jenv, cls);
    if (g_oss_cls == NULL)
        return;

    g_oss_get = (*jenv)->GetStaticMethodID(
        jenv, g_oss_cls, "getBridge", "(Ljava/lang/String;)Ljava/lang/String;"
    );
    g_oss_put = (*jenv)->GetStaticMethodID(
        jenv, g_oss_cls, "putBridge", "(Ljava/lang/String;Ljava/lang/String;)Z"
    );
    g_oss_delete =
        (*jenv)->GetStaticMethodID(jenv, g_oss_cls, "deleteBridge", "(Ljava/lang/String;)Z");

    if ((*jenv)->ExceptionCheck(jenv)) {
        (*jenv)->ExceptionClear(jenv);
    }
}

/* Build {:error, {:jni, atom_reason}}. Kept structurally parallel
 * to the iOS side's oss_sec_error so the Elixir dispatcher can
 * match on a single "was it a store error?" shape. */
static ERL_NIF_TERM oss_jni_error(ErlNifEnv *env, const char *reason) {
    return enif_make_tuple2(
        env, enif_make_atom(env, "error"),
        enif_make_tuple2(env, enif_make_atom(env, "jni"), enif_make_atom(env, reason))
    );
}

/* Copy an Erlang binary into a null-terminated heap buffer for
 * NewStringUTF. Returns NULL on OOM. Caller frees with enif_free. */
static char *oss_nul_terminated(ErlNifBinary *bin) {
    char *buf = enif_alloc(bin->size + 1);
    if (!buf)
        return NULL;
    memcpy(buf, bin->data, bin->size);
    buf[bin->size] = '\0';
    return buf;
}

/* oss_get on Android: calls OperatorSecureStore.getBridge(account).
 *   null → {:ok, nil}
 *   String → {:ok, binary}
 *   JNI failure → {:error, {:jni, atom_reason}} */
static ERL_NIF_TERM oss_android_get(ErlNifEnv *env, ErlNifBinary *acct_bin) {
    int attached = 0;
    JNIEnv *jenv = get_jenv(&attached);
    if (!jenv)
        return oss_jni_error(env, "no_jenv");

    ERL_NIF_TERM result;

    if (oss_android_init(jenv) != 0) {
        result = oss_jni_error(env, "bridge_init_failed");
        goto done;
    }

    char *acct_c = oss_nul_terminated(acct_bin);
    if (!acct_c) {
        result = oss_jni_error(env, "alloc");
        goto done;
    }

    jstring acct_j = (*jenv)->NewStringUTF(jenv, acct_c);
    enif_free(acct_c);
    if (!acct_j || (*jenv)->ExceptionCheck(jenv)) {
        if ((*jenv)->ExceptionCheck(jenv))
            (*jenv)->ExceptionClear(jenv);
        result = oss_jni_error(env, "newstring_failed");
        goto done;
    }

    jobject ret = (*jenv)->CallStaticObjectMethod(jenv, g_oss_cls, g_oss_get, acct_j);
    (*jenv)->DeleteLocalRef(jenv, acct_j);

    if ((*jenv)->ExceptionCheck(jenv)) {
        (*jenv)->ExceptionClear(jenv);
        result = oss_jni_error(env, "call_failed");
        goto done;
    }

    if (ret == NULL) {
        /* Fresh install / key not present — coalesce to {:ok, nil}
         * so the Elixir side reads it the same way it reads iOS's
         * errSecItemNotFound. */
        result = enif_make_tuple2(env, enif_make_atom(env, "ok"), enif_make_atom(env, "nil"));
        goto done;
    }

    const char *r_cstr = (*jenv)->GetStringUTFChars(jenv, (jstring)ret, NULL);
    if (!r_cstr) {
        (*jenv)->DeleteLocalRef(jenv, ret);
        result = oss_jni_error(env, "getchars_failed");
        goto done;
    }

    size_t r_len = strlen(r_cstr);
    ErlNifBinary bin;
    if (!enif_alloc_binary(r_len, &bin)) {
        (*jenv)->ReleaseStringUTFChars(jenv, (jstring)ret, r_cstr);
        (*jenv)->DeleteLocalRef(jenv, ret);
        result = oss_jni_error(env, "alloc");
        goto done;
    }
    memcpy(bin.data, r_cstr, r_len);
    (*jenv)->ReleaseStringUTFChars(jenv, (jstring)ret, r_cstr);
    (*jenv)->DeleteLocalRef(jenv, ret);

    result = enif_make_tuple2(env, enif_make_atom(env, "ok"), enif_make_binary(env, &bin));

done:
    if (attached)
        (*g_jvm)->DetachCurrentThread(g_jvm);
    return result;
}

/* oss_put on Android: calls OperatorSecureStore.putBridge(account, value).
 * commit() returns Boolean — false → {:error, {:jni, :commit_failed}}. */
static ERL_NIF_TERM oss_android_put(ErlNifEnv *env, ErlNifBinary *acct_bin, ErlNifBinary *val_bin) {
    int attached = 0;
    JNIEnv *jenv = get_jenv(&attached);
    if (!jenv)
        return oss_jni_error(env, "no_jenv");

    ERL_NIF_TERM result;

    if (oss_android_init(jenv) != 0) {
        result = oss_jni_error(env, "bridge_init_failed");
        goto done;
    }

    char *acct_c = oss_nul_terminated(acct_bin);
    char *val_c = oss_nul_terminated(val_bin);
    if (!acct_c || !val_c) {
        if (acct_c)
            enif_free(acct_c);
        if (val_c)
            enif_free(val_c);
        result = oss_jni_error(env, "alloc");
        goto done;
    }

    jstring acct_j = (*jenv)->NewStringUTF(jenv, acct_c);
    jstring val_j = (*jenv)->NewStringUTF(jenv, val_c);
    enif_free(acct_c);
    enif_free(val_c);

    if (!acct_j || !val_j || (*jenv)->ExceptionCheck(jenv)) {
        if ((*jenv)->ExceptionCheck(jenv))
            (*jenv)->ExceptionClear(jenv);
        if (acct_j)
            (*jenv)->DeleteLocalRef(jenv, acct_j);
        if (val_j)
            (*jenv)->DeleteLocalRef(jenv, val_j);
        result = oss_jni_error(env, "newstring_failed");
        goto done;
    }

    jboolean ok = (*jenv)->CallStaticBooleanMethod(jenv, g_oss_cls, g_oss_put, acct_j, val_j);
    (*jenv)->DeleteLocalRef(jenv, acct_j);
    (*jenv)->DeleteLocalRef(jenv, val_j);

    if ((*jenv)->ExceptionCheck(jenv)) {
        (*jenv)->ExceptionClear(jenv);
        result = oss_jni_error(env, "call_failed");
        goto done;
    }

    result = ok ? enif_make_atom(env, "ok") : oss_jni_error(env, "commit_failed");

done:
    if (attached)
        (*g_jvm)->DetachCurrentThread(g_jvm);
    return result;
}

/* oss_delete on Android: calls OperatorSecureStore.deleteBridge(account). */
static ERL_NIF_TERM oss_android_delete(ErlNifEnv *env, ErlNifBinary *acct_bin) {
    int attached = 0;
    JNIEnv *jenv = get_jenv(&attached);
    if (!jenv)
        return oss_jni_error(env, "no_jenv");

    ERL_NIF_TERM result;

    if (oss_android_init(jenv) != 0) {
        result = oss_jni_error(env, "bridge_init_failed");
        goto done;
    }

    char *acct_c = oss_nul_terminated(acct_bin);
    if (!acct_c) {
        result = oss_jni_error(env, "alloc");
        goto done;
    }

    jstring acct_j = (*jenv)->NewStringUTF(jenv, acct_c);
    enif_free(acct_c);
    if (!acct_j || (*jenv)->ExceptionCheck(jenv)) {
        if ((*jenv)->ExceptionCheck(jenv))
            (*jenv)->ExceptionClear(jenv);
        result = oss_jni_error(env, "newstring_failed");
        goto done;
    }

    jboolean ok = (*jenv)->CallStaticBooleanMethod(jenv, g_oss_cls, g_oss_delete, acct_j);
    (*jenv)->DeleteLocalRef(jenv, acct_j);

    if ((*jenv)->ExceptionCheck(jenv)) {
        (*jenv)->ExceptionClear(jenv);
        result = oss_jni_error(env, "call_failed");
        goto done;
    }

    /* Idempotent — SharedPreferences.remove returns true even for
     * a missing key, matching iOS's errSecItemNotFound → :ok. */
    result = ok ? enif_make_atom(env, "ok") : oss_jni_error(env, "commit_failed");

done:
    if (attached)
        (*g_jvm)->DetachCurrentThread(g_jvm);
    return result;
}

#endif /* OPERATOR_SECURE_STORE_HAVE_ANDROID */

/* ─── NIFs ────────────────────────────────────────────────────── */

static ERL_NIF_TERM oss_get(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
#ifdef OPERATOR_SECURE_STORE_HAVE_KEYCHAIN
    ErlNifBinary acct_bin;
    if (!enif_inspect_binary(env, argv[0], &acct_bin))
        return enif_make_badarg(env);

    CFStringRef account = oss_binary_to_cfstring(&acct_bin);
    /* Non-UTF-8 account bytes — this is a caller mistake, not a
     * Security allocation error. Surface as badarg so tests / logs
     * distinguish it from real Keychain memory pressure. */
    if (!account)
        return enif_make_badarg(env);

    CFMutableDictionaryRef query = oss_base_query(account);
    CFDictionarySetValue(query, kSecReturnData, kCFBooleanTrue);
    CFDictionarySetValue(query, kSecMatchLimit, kSecMatchLimitOne);

    CFTypeRef out = NULL;
    OSStatus st = SecItemCopyMatching(query, &out);

    ERL_NIF_TERM result;

    /* Coalesce two "no data" outcomes into {:ok, nil}:
     *   - errSecItemNotFound (the documented "no such item")
     *   - errSecSuccess but out == NULL (defensive: any SDK/SEP
     *     quirk that skips populating the out pointer used to
     *     surface as {:error, {:sec, 0}}, which reads as a
     *     self-contradictory "success is failure" log line) */
    if (st == errSecItemNotFound || (st == errSecSuccess && out == NULL)) {
        result = enif_make_tuple2(env, enif_make_atom(env, "ok"), enif_make_atom(env, "nil"));
    } else if (st == errSecSuccess) {
        CFDataRef data = (CFDataRef)out;
        CFIndex len = CFDataGetLength(data);
        ErlNifBinary bin;
        /* Check the alloc — enif_alloc_binary returns 0 on failure
         * and bin.data is undefined then. Segfault-in-native beats
         * a debuggable Elixir error. */
        if (!enif_alloc_binary((size_t)len, &bin)) {
            if (out)
                CFRelease(out);
            CFRelease(query);
            CFRelease(account);
            return oss_sec_error(env, errSecAllocate);
        }
        memcpy(bin.data, CFDataGetBytePtr(data), (size_t)len);
        result = enif_make_tuple2(env, enif_make_atom(env, "ok"), enif_make_binary(env, &bin));
    } else {
        result = oss_sec_error(env, st);
    }

    if (out)
        CFRelease(out);
    CFRelease(query);
    CFRelease(account);
    return result;
#elif defined(OPERATOR_SECURE_STORE_HAVE_ANDROID)
    ErlNifBinary acct_bin;
    if (!enif_inspect_binary(env, argv[0], &acct_bin))
        return enif_make_badarg(env);
    return oss_android_get(env, &acct_bin);
#else
    (void)env;
    (void)argv;
    return enif_raise_exception(
        env, enif_make_atom(env, "secure_store_not_available_on_this_platform")
    );
#endif
}

static ERL_NIF_TERM oss_put(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
#ifdef OPERATOR_SECURE_STORE_HAVE_KEYCHAIN
    ErlNifBinary acct_bin, val_bin;
    if (!enif_inspect_binary(env, argv[0], &acct_bin))
        return enif_make_badarg(env);
    if (!enif_inspect_binary(env, argv[1], &val_bin))
        return enif_make_badarg(env);

    CFStringRef account = oss_binary_to_cfstring(&acct_bin);
    CFDataRef value = oss_binary_to_cfdata(&val_bin);
    /* Non-UTF-8 account → badarg (caller mistake, not a Security
     * allocation problem). CFDataCreate for value returning NULL
     * is a real memory failure. */
    if (!account) {
        if (value)
            CFRelease(value);
        return enif_make_badarg(env);
    }
    if (!value) {
        CFRelease(account);
        return oss_sec_error(env, errSecAllocate);
    }

    /* Upsert as Add-first, Update-on-duplicate. Inverse of
     * Update-first would race: two concurrent writers both see
     * errSecItemNotFound on their Updates, both go to Add, second
     * loses with errSecDuplicateItem.
     *
     * kSecAttrAccessible is set ONLY on the Add path — putting it
     * in oss_base_query would make it a MATCH filter on
     * Update/Copy/Delete, so a future accessibility change would
     * orphan existing items (Update sees not-found → Add sees
     * duplicate → user locked out). */
    CFMutableDictionaryRef add_query = oss_base_query(account);
    CFDictionarySetValue(add_query, kSecValueData, value);
    CFDictionarySetValue(
        add_query, kSecAttrAccessible, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    );

    OSStatus st = SecItemAdd(add_query, NULL);
    CFRelease(add_query);

    if (st == errSecDuplicateItem) {
        /* Item exists — update it in place. */
        CFMutableDictionaryRef match = oss_base_query(account);
        CFMutableDictionaryRef attrs = CFDictionaryCreateMutable(
            kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks
        );
        CFDictionarySetValue(attrs, kSecValueData, value);

        st = SecItemUpdate(match, attrs);

        CFRelease(attrs);
        CFRelease(match);
    }

    ERL_NIF_TERM result =
        (st == errSecSuccess) ? enif_make_atom(env, "ok") : oss_sec_error(env, st);

    CFRelease(value);
    CFRelease(account);
    return result;
#elif defined(OPERATOR_SECURE_STORE_HAVE_ANDROID)
    ErlNifBinary acct_bin, val_bin;
    if (!enif_inspect_binary(env, argv[0], &acct_bin))
        return enif_make_badarg(env);
    if (!enif_inspect_binary(env, argv[1], &val_bin))
        return enif_make_badarg(env);
    return oss_android_put(env, &acct_bin, &val_bin);
#else
    (void)env;
    (void)argv;
    return enif_raise_exception(
        env, enif_make_atom(env, "secure_store_not_available_on_this_platform")
    );
#endif
}

static ERL_NIF_TERM oss_delete(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
#ifdef OPERATOR_SECURE_STORE_HAVE_KEYCHAIN
    ErlNifBinary acct_bin;
    if (!enif_inspect_binary(env, argv[0], &acct_bin))
        return enif_make_badarg(env);

    CFStringRef account = oss_binary_to_cfstring(&acct_bin);
    if (!account)
        return enif_make_badarg(env);

    CFMutableDictionaryRef query = oss_base_query(account);
    OSStatus st = SecItemDelete(query);

    ERL_NIF_TERM result;
    if (st == errSecSuccess || st == errSecItemNotFound) {
        result = enif_make_atom(env, "ok");
    } else {
        result = oss_sec_error(env, st);
    }

    CFRelease(query);
    CFRelease(account);
    return result;
#elif defined(OPERATOR_SECURE_STORE_HAVE_ANDROID)
    ErlNifBinary acct_bin;
    if (!enif_inspect_binary(env, argv[0], &acct_bin))
        return enif_make_badarg(env);
    return oss_android_delete(env, &acct_bin);
#else
    (void)env;
    (void)argv;
    return enif_raise_exception(
        env, enif_make_atom(env, "secure_store_not_available_on_this_platform")
    );
#endif
}

static ErlNifFunc nif_funcs[] = {
    {"get", 1, oss_get, 0}, {"put", 2, oss_put, 0}, {"delete", 1, oss_delete, 0}
};

ERL_NIF_INIT(Elixir.Operator.Nifs.OperatorSecureStore, nif_funcs, NULL, NULL, NULL, NULL)
