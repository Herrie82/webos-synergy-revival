// dave_probe.cpp — libdave / DAVE (Discord Audio & Video End-to-end encryption)
// API probe for the HP TouchPad (webOS, ARMv7 glibc) FOUNDATION spike.
//
// PURPOSE
//   Prove the libdave public API surface we will need for a real Discord audio
//   client links and runs on the device toolchain, and pin down the EXACT call
//   sequence. This is NOT a Discord client and does NOT talk to any network.
//
//   It exercises two independent slices of the DAVE protocol:
//
//   PART A — MLS key material (C API, includes/dave/dave.h)
//     daveSessionCreate -> daveSessionInit -> daveSessionGetMarshalledKeyPackage
//     Proves that the MLS layer (via mlspp) generates a real P256 signature key,
//     an HPKE init key, a LeafNode and a serialized MLS KeyPackage — this is the
//     blob a client sends to the voice gateway (DAVE opcode 26, MLS_KEY_PACKAGE).
//
//   PART B — per-frame media crypto (internal C++ API, src/*.h)
//     CreateEncryptor / CreateDecryptor + two MlsKeyRatchet objects that share an
//     identical MLS "base secret" (this is what the MLS group's MLS-Exporter
//     'Discord Secure Frames v0' produces for a sender, post-handshake). Encrypt
//     one Opus-sized audio frame and decrypt it back, byte-for-byte. Proves the
//     custom AES-128-GCM framing (magic 0xFAFA, 8-byte truncated tag, ULEB128
//     truncated-nonce, per-generation HashRatchet key) round-trips on-device.
//
// WHAT IT DOES NOT DO
//   The full 2-party MLS handshake (external-sender package -> add proposals ->
//   commit/welcome) needs the voice server's ExternalSender credential, which is
//   issued live by Discord over the voice websocket (DAVE opcode 25). That cannot
//   be fabricated offline, so Part B injects a shared base secret directly to test
//   the media-crypto datapath in isolation. See PLAN.md milestone M2.

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

// ---- DAVE public C API -------------------------------------------------------
#include <dave/dave.h>

// ---- DAVE internal C++ API (media crypto datapath) ---------------------------
#include <dave/dave_interfaces.h> // discord::dave::CreateEncryptor / CreateDecryptor
#include "mls_key_ratchet.h"      // discord::dave::MlsKeyRatchet
#include "common.h"               // kAesGcm128*, kSupplementalBytes, kMarkerBytes

// ---- mlspp (for the CipherSuite + bytes types) -------------------------------
#include <mls/crypto.h>        // mlspp::CipherSuite
#include <bytes/bytes.h>       // mlspp::bytes_ns::bytes

using namespace discord::dave;

static int g_failures = 0;
#define CHECK(cond, msg)                                                        \
    do {                                                                        \
        if (!(cond)) { std::printf("  [FAIL] %s\n", msg); ++g_failures; }       \
        else         { std::printf("  [ ok ] %s\n", msg); }                     \
    } while (0)

static void mlsFailure(const char* source, const char* reason, void* /*u*/)
{
    std::printf("  [MLS-FAIL] source=%s reason=%s\n",
                source ? source : "(null)", reason ? reason : "(null)");
}

// -----------------------------------------------------------------------------
// PART A — MLS key package generation via the stable C API
// -----------------------------------------------------------------------------
static void partA_keyPackage()
{
    std::printf("\n== PART A: MLS key package (C API) ==\n");

    std::printf("  daveMaxSupportedProtocolVersion() = %u\n",
                (unsigned)daveMaxSupportedProtocolVersion());

    // IMPORTANT: authSessionId MUST be NULL/empty in this build.
    //   Session stores authSessionId as signingKeyId_. A NON-empty signingKeyId_
    //   routes InitLeafNode down the GetPersistedKeyPair() path, which is a no-op
    //   because we built with PERSISTENT_KEYS=OFF -> no leaf node -> no key package.
    //   An EMPTY signingKeyId_ makes InitLeafNode generate a transient
    //   SignaturePrivateKey::generate(suite) in-memory -> leaf node -> key package.
    //   The real client either builds PERSISTENT_KEYS=ON, or calls the C++
    //   ISession::Init() with its own transient signature key. (See PLAN.md M2.)
    DAVESessionHandle s = daveSessionCreate(nullptr, /*authSessionId*/ nullptr,
                                            mlsFailure, nullptr);
    CHECK(s != nullptr, "daveSessionCreate returned a session handle");
    if (!s) return;

    // groupId is the Discord channel id in the real protocol; selfUserId is our
    // Discord user id (decimal snowflake string).
    const uint16_t version = daveMaxSupportedProtocolVersion();
    daveSessionInit(s, version, /*groupId*/ 0x0123456789abcdefULL,
                    /*selfUserId*/ "111111111111111111");
    CHECK(daveSessionGetProtocolVersion(s) == version,
          "daveSessionInit set the protocol version");

    uint8_t* kp = nullptr;
    size_t   kpLen = 0;
    daveSessionGetMarshalledKeyPackage(s, &kp, &kpLen);
    std::printf("  marshalled KeyPackage length = %zu bytes\n", kpLen);
    CHECK(kp != nullptr && kpLen > 0,
          "daveSessionGetMarshalledKeyPackage produced a non-empty MLS KeyPackage");
    if (kp && kpLen >= 4) {
        std::printf("  KeyPackage[0..3] = %02x %02x %02x %02x\n",
                    kp[0], kp[1], kp[2], kp[3]);
    }
    daveFree(kp);
    daveSessionDestroy(s);
}

// -----------------------------------------------------------------------------
// PART B — media-frame AES-128-GCM round-trip via the internal C++ API
// -----------------------------------------------------------------------------
static void partB_frameRoundTrip()
{
    std::printf("\n== PART B: Opus frame encrypt/decrypt round-trip ==\n");

    // DAVE ciphersuite 0x0002 (P256_AES128GCM_SHA256_P256).
    ::mlspp::CipherSuite suite{::mlspp::CipherSuite::ID::P256_AES128GCM_SHA256_P256};

    // The shared "base secret" a sender's MlsKeyRatchet is seeded with post-MLS.
    // In the real protocol this comes from MLS-Exporter("Discord Secure Frames v0",
    // senderUserId, 16-ish) and is identical on both peers for a given sender.
    // Here we inject the same 32-byte secret into both ratchets to model that.
    std::vector<uint8_t> baseSecretBytes(32);
    for (size_t i = 0; i < baseSecretBytes.size(); ++i)
        baseSecretBytes[i] = static_cast<uint8_t>(0xA0 + i);
    ::mlspp::bytes_ns::bytes baseSecret{baseSecretBytes};

    const uint32_t ssrc = 0xDEADBEEF;

    // Sender side
    auto enc = CreateEncryptor();
    CHECK(enc != nullptr, "CreateEncryptor()");
    enc->SetKeyRatchet(std::make_unique<MlsKeyRatchet>(suite, baseSecret));
    enc->AssignSsrcToCodec(ssrc, Codec::Opus);
    enc->SetPassthroughMode(false);
    CHECK(enc->HasKeyRatchet(), "encryptor has key ratchet");
    CHECK(!enc->IsPassthroughMode(), "encryptor is NOT in passthrough mode");

    // Receiver side (same base secret -> same HashRatchet -> same per-gen keys)
    auto dec = CreateDecryptor();
    CHECK(dec != nullptr, "CreateDecryptor()");
    dec->TransitionToKeyRatchet(std::make_unique<MlsKeyRatchet>(suite, baseSecret));

    // A plausible ~ 20 ms Opus voice payload (contents are opaque for audio: DAVE
    // encrypts the WHOLE audio frame, no codec carve-outs).
    std::vector<uint8_t> plain(160);
    for (size_t i = 0; i < plain.size(); ++i)
        plain[i] = static_cast<uint8_t>(i * 7 + 3);

    size_t maxCt = enc->GetMaxCiphertextByteSize(MediaType::Audio, plain.size());
    std::printf("  plaintext=%zu bytes, max ciphertext=%zu bytes (overhead=%zd)\n",
                plain.size(), maxCt, (ssize_t)maxCt - (ssize_t)plain.size());
    std::vector<uint8_t> cipher(maxCt);

    size_t ctWritten = 0;
    auto er = enc->Encrypt(MediaType::Audio, ssrc,
                           {plain.data(), plain.size()},
                           {cipher.data(), cipher.size()}, &ctWritten);
    std::printf("  Encrypt result=%d bytesWritten=%zu\n", (int)er, ctWritten);
    CHECK(er == IEncryptor::ResultCode::Success, "Encrypt returned Success");
    CHECK(ctWritten > plain.size(), "ciphertext is larger than plaintext (tag+nonce+magic)");

    // Confirm the DAVE magic marker 0xFAFA is present near the end of the frame.
    bool sawMagic = false;
    for (size_t i = 0; i + 1 < ctWritten; ++i) {
        uint16_t m = (uint16_t)cipher[i] | ((uint16_t)cipher[i + 1] << 8);
        uint16_t mbe = ((uint16_t)cipher[i] << 8) | (uint16_t)cipher[i + 1];
        if (m == kMarkerBytes || mbe == kMarkerBytes) { sawMagic = true; break; }
    }
    CHECK(sawMagic, "encrypted frame carries the 0xFAFA magic marker");

    // Decrypt
    size_t maxPt = dec->GetMaxPlaintextByteSize(MediaType::Audio, ctWritten);
    std::vector<uint8_t> out(maxPt ? maxPt : plain.size());
    size_t ptWritten = 0;
    auto dr = dec->Decrypt(MediaType::Audio,
                           {cipher.data(), ctWritten},
                           {out.data(), out.size()}, &ptWritten);
    std::printf("  Decrypt result=%d bytesWritten=%zu\n", (int)dr, ptWritten);
    CHECK(dr == IDecryptor::ResultCode::Success, "Decrypt returned Success");
    CHECK(ptWritten == plain.size(), "decrypted length matches original");
    CHECK(ptWritten == plain.size() &&
          std::memcmp(out.data(), plain.data(), plain.size()) == 0,
          "decrypted bytes match original plaintext (round-trip OK)");
}

int main()
{
    std::printf("=== DAVE / libdave API probe (ARMv7 webOS foundation spike) ===\n");
    partA_keyPackage();
    partB_frameRoundTrip();

    std::printf("\n=== %s (%d check failure%s) ===\n",
                g_failures == 0 ? "ALL CHECKS PASSED" : "SOME CHECKS FAILED",
                g_failures, g_failures == 1 ? "" : "s");
    return g_failures == 0 ? 0 : 1;
}
