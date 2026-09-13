// Exports exactly the owner-approved identity, never an entire keychain.
// Secrets arrive on stdin and the encrypted PKCS#12 leaves on a private pipe.
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <CommonCrypto/CommonDigest.h>
#include <sys/resource.h>
#include <unistd.h>

static NSString *const ApprovedSHA256 = @"c38e12abd12b6c4ab0904f096f036e63596a25527de6123d4d7a2778420ece46";
static NSString *const ApprovedSubject = @"Developer ID Application: Yapio (4KH7528725)";

static int fail(const char *message) {
    fprintf(stderr, "%s\n", message); // Fixed messages only; never input or OS error objects.
    return 1;
}

static NSString *fingerprint(NSData *data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:64];
    for (unsigned i = 0; i < sizeof(digest); ++i) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

int main(int argc, const char *argv[]) {
    struct rlimit noCore = {0, 0};
    if (setrlimit(RLIMIT_CORE, &noCore) != 0) return fail("Cannot disable core dumps.");
    @autoreleasepool {
        if (argc != 2 || (strcmp(argv[1], "inspect") && strcmp(argv[1], "export")))
            return fail("Usage: export_identity inspect|export");
        BOOL exporting = strcmp(argv[1], "export") == 0;
        NSString *passphrase = nil;
        if (exporting) {
            // Refuse accidental terminal output or an interactive password prompt.
            if (isatty(STDIN_FILENO) || isatty(STDOUT_FILENO))
                return fail("Export requires private input and output pipes.");
            NSData *input = [[NSFileHandle fileHandleWithStandardInput] readDataOfLength:8193];
            if (input.length == 0 || input.length > 8192) return fail("Invalid export request.");
            id request = [NSJSONSerialization JSONObjectWithData:input options:0 error:nil];
            if (![request isKindOfClass:[NSDictionary class]] || [request count] != 2 ||
                ![request[@"certificate_sha256"] isEqual:ApprovedSHA256] ||
                ![request[@"passphrase"] isKindOfClass:[NSString class]])
                return fail("Export request does not match the approved certificate.");
            passphrase = request[@"passphrase"];
            if (passphrase.length < 43 || passphrase.length > 128)
                return fail("Export requires a strong generated passphrase.");
        }

        // Enumerate public certificates only; do not enumerate or export private keys.
        NSDictionary *query = @{(__bridge id)kSecClass: (__bridge id)kSecClassCertificate,
                                (__bridge id)kSecReturnRef: @YES,
                                (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll};
        CFTypeRef found = NULL;
        OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &found);
        if (status != errSecSuccess || !found) return fail("Cannot read public certificates.");
        NSArray *certificates = CFBridgingRelease(found);
        SecCertificateRef selected = NULL;
        NSData *selectedDER = nil;
        for (id value in certificates) {
            SecCertificateRef certificate = (__bridge SecCertificateRef)value;
            NSData *der = CFBridgingRelease(SecCertificateCopyData(certificate));
            if (![fingerprint(der) isEqual:ApprovedSHA256]) continue;
            NSString *subject = CFBridgingRelease(SecCertificateCopySubjectSummary(certificate));
            if (![subject isEqual:ApprovedSubject]) return fail("Certificate subject mismatch.");
            selected = certificate;
            selectedDER = der;
            break; // Identical certificate copies are not separate export targets.
        }
        if (!selected) return fail("The exact approved certificate was not found.");
        if (!exporting) {
            NSDictionary *output = @{@"certificate_sha256": ApprovedSHA256,
                                     @"subject": ApprovedSubject,
                                     @"certificate_der": [selectedDER base64EncodedStringWithOptions:0]};
            NSData *json = [NSJSONSerialization dataWithJSONObject:output options:0 error:nil];
            return fwrite(json.bytes, 1, json.length, stdout) == json.length ? 0 : 1;
        }

        // Only after exact public-certificate selection request its matching identity.
        SecIdentityRef identity = NULL;
        status = SecIdentityCreateWithCertificate(NULL, selected, &identity);
        if (status != errSecSuccess || !identity) return fail("Matching private identity unavailable.");
        SecItemImportExportKeyParameters parameters = {0};
        parameters.version = SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION;
        parameters.passphrase = (__bridge CFStringRef)passphrase;
        CFDataRef exported = NULL;
        status = SecItemExport(identity, kSecFormatPKCS12, 0, &parameters, &exported);
        CFRelease(identity);
        if (status != errSecSuccess || !exported) return fail("Exact identity export was denied or failed.");
        NSData *encrypted = CFBridgingRelease(exported);
        if (!encrypted.length || encrypted.length > 49152) return fail("Unexpected encrypted identity size.");
        return fwrite(encrypted.bytes, 1, encrypted.length, stdout) == encrypted.length ? 0 : 1;
    }
}
