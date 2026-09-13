// Import one encrypted identity into a new, private, disposable CI keychain.
// All secret parameters arrive through stdin, not argv or environment variables.
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <CommonCrypto/CommonDigest.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <unistd.h>

// File-based codesign keychains still use these public legacy Security APIs.
// Keep this compatibility boundary isolated; do not use private Security APIs.
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

static NSString *hex(NSData *data) {
    const unsigned char *bytes = data.bytes;
    NSMutableString *value = [NSMutableString stringWithCapacity:data.length * 2];
    for (NSUInteger i = 0; i < data.length; ++i) [value appendFormat:@"%02x", bytes[i]];
    return value;
}

static BOOL stringField(id request, NSString *key) {
    return [request[key] isKindOfClass:[NSString class]] && [request[key] length] > 0;
}

static BOOL verifyCodesignACL(SecIdentityRef identity, SecTrustedApplicationRef codesign) {
    SecKeyRef key = NULL;
    SecAccessRef access = NULL;
    if (SecIdentityCopyPrivateKey(identity, &key) != errSecSuccess) return NO;
    OSStatus status = SecKeychainItemCopyAccess((SecKeychainItemRef)key, &access);
    CFRelease(key);
    if (status != errSecSuccess || !access) return NO;
    NSArray *rules = CFBridgingRelease(SecAccessCopyMatchingACLList(access, kSecACLAuthorizationSign));
    BOOL valid = rules.count > 0;
    for (id rule in rules) {
        CFArrayRef applications = NULL;
        CFStringRef description = NULL;
        SecKeychainPromptSelector prompt = 0;
        status = SecACLCopyContents((__bridge SecACLRef)rule, &applications, &description, &prompt);
        // A NULL application list authorizes ANY application. Never accept it.
        valid = valid && status == errSecSuccess && applications && CFArrayGetCount(applications) == 1;
        if (valid) {
            CFDataRef actual = NULL, expected = NULL;
            valid = SecTrustedApplicationCopyData((SecTrustedApplicationRef)CFArrayGetValueAtIndex(applications, 0), &actual) == errSecSuccess &&
                    SecTrustedApplicationCopyData(codesign, &expected) == errSecSuccess && actual && expected && CFEqual(actual, expected);
            if (actual) CFRelease(actual);
            if (expected) CFRelease(expected);
        }
        if (applications) CFRelease(applications);
        if (description) CFRelease(description);
    }
    NSArray *partitions = CFBridgingRelease(SecAccessCopyMatchingACLList(access, kSecACLAuthorizationPartitionID));
    valid = valid && partitions.count == 1;
    if (valid) {
        CFArrayRef applications = NULL;
        CFStringRef description = NULL;
        SecKeychainPromptSelector prompt = 0;
        status = SecACLCopyContents((__bridge SecACLRef)partitions[0], &applications, &description, &prompt);
        NSData *expected = [NSPropertyListSerialization dataWithPropertyList:@{@"Partitions": @[@"apple-tool:"]}
                                                format:NSPropertyListXMLFormat_v1_0 options:0 error:nil];
        valid = status == errSecSuccess && description && [(__bridge NSString *)description isEqual:hex(expected)];
        if (applications) CFRelease(applications);
        if (description) CFRelease(description);
    }
    CFRelease(access);
    return valid;
}

int main(int argc, __unused const char *argv[]) {
    struct rlimit noCore = {0, 0};
    if (setrlimit(RLIMIT_CORE, &noCore) || argc != 1 || isatty(STDIN_FILENO)) return 1;
    @autoreleasepool {
        NSData *input = [[NSFileHandle fileHandleWithStandardInput] readDataOfLength:131073];
        if (input.length == 0 || input.length > 131072) return 1;
        id request = [NSJSONSerialization JSONObjectWithData:input options:0 error:nil];
        if (![request isKindOfClass:[NSDictionary class]] || [request count] != 5) return 1;
        for (NSString *key in @[@"keychain_path", @"keychain_password", @"p12_password", @"p12", @"certificate_sha256"])
            if (!stringField(request, key)) return 1;
        NSString *path = request[@"keychain_path"];
        NSString *expected = request[@"certificate_sha256"];
        if (![path isAbsolutePath] || ![[path lastPathComponent] isEqual:@"signing.keychain-db"] ||
            [request[@"keychain_password"] length] < 43 || [request[@"p12_password"] length] < 32 ||
            expected.length != 64) return 1;
        struct stat parentStat, targetStat;
        if (lstat([[path stringByDeletingLastPathComponent] fileSystemRepresentation], &parentStat) ||
            !S_ISDIR(parentStat.st_mode) || parentStat.st_uid != geteuid() ||
            (parentStat.st_mode & 077) != 0 || lstat([path fileSystemRepresentation], &targetStat) == 0) return 1;
        NSData *p12 = [[NSData alloc] initWithBase64EncodedString:request[@"p12"] options:0];
        NSData *password = [request[@"keychain_password"] dataUsingEncoding:NSUTF8StringEncoding];
        if (!p12.length || p12.length > 49152) return 1;

        SecKeychainRef keychain = NULL;
        SecAccessRef access = NULL;
        SecTrustedApplicationRef codesign = NULL;
        CFArrayRef oldSearchList = NULL, imported = NULL;
        SecCertificateRef certificate = NULL;
        int result = 1;
        // A CI runner must fail closed instead of showing authorization prompts.
        SecKeychainSetUserInteractionAllowed(false);
        if (SecKeychainCopySearchList(&oldSearchList) != errSecSuccess) goto cleanup;
        if (SecKeychainCreate(path.fileSystemRepresentation, (UInt32)password.length, password.bytes,
                              false, NULL, &keychain) != errSecSuccess) goto cleanup;
        {
            SecKeychainSettings settings = {SEC_KEYCHAIN_SETTINGS_VERS1, false, true, 21600};
            if (SecKeychainSetSettings(keychain, &settings) != errSecSuccess) goto cleanup;
        }
        // A concrete Apple-signed system executable, never NULL (allow-any-app).
        if (SecTrustedApplicationCreateFromPath("/usr/bin/codesign", &codesign) != errSecSuccess) goto cleanup;
        {
            NSArray *trusted = @[(__bridge id)codesign];
            if (SecAccessCreate(CFSTR("Mokaid CI signing key"), (__bridge CFArrayRef)trusted, &access) != errSecSuccess)
                goto cleanup;
            // Apple file-keychain partition ACL uses a hex-encoded XML plist.
            // The trusted-application ACL above additionally restricts key access
            // to /usr/bin/codesign; this is not an allow-all signing-key ACL.
            NSData *partitionData = [NSPropertyListSerialization dataWithPropertyList:@{@"Partitions": @[@"apple-tool:"]}
                                                format:NSPropertyListXMLFormat_v1_0 options:0 error:nil];
            SecACLRef partition = NULL;
            if (!partitionData || SecACLCreateWithSimpleContents(access, (__bridge CFArrayRef)trusted,
                    (__bridge CFStringRef)hex(partitionData), 0, &partition) != errSecSuccess) goto cleanup;
            NSArray *authorizations = @[(__bridge id)kSecACLAuthorizationPartitionID];
            OSStatus status = SecACLUpdateAuthorizations(partition, (__bridge CFArrayRef)authorizations);
            CFRelease(partition);
            if (status != errSecSuccess) goto cleanup;
            NSDictionary *options = @{(__bridge id)kSecImportExportPassphrase: request[@"p12_password"],
                                      (__bridge id)kSecImportExportKeychain: (__bridge id)keychain,
                                      (__bridge id)kSecImportExportAccess: (__bridge id)access};
            if (SecPKCS12Import((__bridge CFDataRef)p12, (__bridge CFDictionaryRef)options, &imported) != errSecSuccess)
                goto cleanup;
        }
        if (!imported || CFArrayGetCount(imported) != 1) goto cleanup;
        {
            NSDictionary *item = (__bridge NSDictionary *)CFArrayGetValueAtIndex(imported, 0);
            SecIdentityRef identity = (__bridge SecIdentityRef)item[(__bridge id)kSecImportItemIdentity];
            if (!identity || SecIdentityCopyCertificate(identity, &certificate) != errSecSuccess) goto cleanup;
            if (!verifyCodesignACL(identity, codesign)) goto cleanup;
            NSData *der = CFBridgingRelease(SecCertificateCopyData(certificate));
            unsigned char sha256[CC_SHA256_DIGEST_LENGTH], sha1[CC_SHA1_DIGEST_LENGTH];
            CC_SHA256(der.bytes, (CC_LONG)der.length, sha256);
            if (![hex([NSData dataWithBytes:sha256 length:sizeof sha256]) isEqual:expected]) goto cleanup;
            // codesign accepts the exact certificate's SHA1 selector. SHA256
            // above authenticates the certificate; SHA1 is only its keychain ID.
            CC_SHA1(der.bytes, (CC_LONG)der.length, sha1);
            NSData *output = [NSJSONSerialization dataWithJSONObject:@{@"certificate_sha256": expected, @"codesign_acl_verified": @YES,
                @"codesign_identity": hex([NSData dataWithBytes:sha1 length:sizeof sha1])} options:0 error:nil];
            if (!output || fwrite(output.bytes, 1, output.length, stdout) != output.length) goto cleanup;
            result = 0;
        }
    cleanup:
        if (oldSearchList && SecKeychainSetSearchList(oldSearchList) != errSecSuccess) result = 1;
        if (result != 0 && keychain) SecKeychainDelete(keychain);
        if (certificate) CFRelease(certificate);
        if (imported) CFRelease(imported);
        if (access) CFRelease(access);
        if (codesign) CFRelease(codesign);
        if (keychain) CFRelease(keychain);
        if (oldSearchList) CFRelease(oldSearchList);
        if (result) fprintf(stderr, "Temporary signing keychain import or verification failed.\n");
        return result;
    }
}
