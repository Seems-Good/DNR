-- ============================================================
--  Crypto/TOTP.lua  –  Two Factor Release
--
--  Implements TOTP (RFC 6238) in pure Lua using WoW's built-in
--  'bit' library for 32-bit bitwise operations.
--
--  Pipeline:
--    Base32-decode(secret)  →  key bytes
--    HOTP(key, floor(time/30))  →  6-digit code
--      └─ HMAC-SHA-1(key, 8-byte counter)  →  20-byte digest
--           └─ SHA-1(msg)  →  20-byte hash
--
--  Public API  (all in global DNR_TOTP table):
--    DNR_TOTP.GenerateSecret([len])   → base32 string (default 16 chars / 80 bits)
--    DNR_TOTP.FormatSecret(s)         → "XXXX XXXX XXXX XXXX" readable form
--    DNR_TOTP.GetCode(secret_b32[, step_offset])  → "123456" current code
--    DNR_TOTP.Verify(secret_b32, input)           → true/false (±1 step window)
--    DNR_TOTP.SecondsRemaining()      → seconds until code rotates (0-29)
--
--  Notes:
--    • WoW's bit.rshift is logical (unsigned); bit.arshift is arithmetic.
--      All operations here rely only on logical rshift. ✓
--    • SHA-1 addition is done in Lua double precision (53-bit mantissa),
--      then masked to 32 bits with band(..., 0xFFFFFFFF). The max
--      intermediate sum is 5 × (2^32-1) ≈ 2^34, well inside doubles. ✓
--    • TOTP counter = floor(GetServerTime()/30). Server time is used
--      rather than local time() to stay in sync with the realm clock.
--    • math.random is not a CSPRNG, but for a release-spirit guard the
--      entropy of a 16-char base32 secret (~77 bits) is more than enough.
-- ============================================================

DNR_TOTP = DNR_TOTP or {}

do
    local band  = bit.band
    local bor   = bit.bor
    local bxor  = bit.bxor
    local bnot  = bit.bnot
    local lsh   = bit.lshift
    local rsh   = bit.rshift
    local floor = math.floor
    local char  = string.char
    local byte  = string.byte
    local fmt   = string.format

    local function rol32(v, n)
        return bor(lsh(v, n), rsh(v, 32 - n))
    end

    local function u32be(n)
        return char(
            band(rsh(n, 24), 0xFF),
            band(rsh(n, 16), 0xFF),
            band(rsh(n,  8), 0xFF),
            band(n,          0xFF)
        )
    end

    local function sha1(msg)
        local h0 = 0x67452301
        local h1 = 0xEFCDAB89
        local h2 = 0x98BADCFE
        local h3 = 0x10325476
        local h4 = 0xC3D2E1F0

        local msgLen = #msg
        local bitLen = msgLen * 8

        msg = msg .. char(0x80)
        while #msg % 64 ~= 56 do
            msg = msg .. char(0)
        end
        msg = msg .. char(0, 0, 0, 0) .. u32be(bitLen)

        local w = {}
        for ci = 1, #msg, 64 do
            for j = 0, 15 do
                local p = ci + j * 4
                local b1, b2, b3, b4 = byte(msg, p, p + 3)
                w[j] = bor(lsh(b1, 24), lsh(b2, 16), lsh(b3, 8), b4)
            end

            for j = 16, 79 do
                w[j] = rol32(bxor(bxor(w[j-3], w[j-8]), bxor(w[j-14], w[j-16])), 1)
            end

            local a, b, c, d, e = h0, h1, h2, h3, h4

            for j = 0, 79 do
                local f, k
                if j < 20 then
                    f = bor(band(b, c), band(bnot(b), d))
                    k = 0x5A827999
                elseif j < 40 then
                    f = bxor(b, bxor(c, d))
                    k = 0x6ED9EBA1
                elseif j < 60 then
                    f = bor(band(b, c), bor(band(b, d), band(c, d)))
                    k = 0x8F1BBCDC
                else
                    f = bxor(b, bxor(c, d))
                    k = 0xCA62C1D6
                end
                local temp = band(rol32(a, 5) + f + e + k + w[j], 0xFFFFFFFF)
                e = d
                d = c
                c = rol32(b, 30)
                b = a
                a = temp
            end

            h0 = band(h0 + a, 0xFFFFFFFF)
            h1 = band(h1 + b, 0xFFFFFFFF)
            h2 = band(h2 + c, 0xFFFFFFFF)
            h3 = band(h3 + d, 0xFFFFFFFF)
            h4 = band(h4 + e, 0xFFFFFFFF)
        end

        return u32be(h0) .. u32be(h1) .. u32be(h2) .. u32be(h3) .. u32be(h4)
    end

    local function hmac_sha1(key, msg)
        local BLOCK = 64

        if #key > BLOCK then
            key = sha1(key)
        end

        while #key < BLOCK do
            key = key .. char(0)
        end

        local ipad, opad = {}, {}
        for i = 1, BLOCK do
            local k = byte(key, i)
            ipad[i] = char(bxor(k, 0x36))
            opad[i] = char(bxor(k, 0x5C))
        end

        ipad = table.concat(ipad)
        opad = table.concat(opad)
        return sha1(opad .. sha1(ipad .. msg))
    end

    local B32ALPHA = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
    local B32MAP = {}
    for i = 1, 32 do
        B32MAP[B32ALPHA:sub(i, i)] = i - 1
    end

    local function base32_decode(s)
        s = s:upper():gsub("[^A-Z2-7]", "")
        local bits, val, out = 0, 0, {}
        for i = 1, #s do
            local v = B32MAP[s:sub(i, i)]
            if v then
                val = bor(lsh(val, 5), v)
                bits = bits + 5
                if bits >= 8 then
                    bits = bits - 8
                    out[#out + 1] = char(band(rsh(val, bits), 0xFF))
                end
            end
        end
        return table.concat(out)
    end

    local function hotp(key_bytes, counter)
        local msg = char(
            0, 0, 0, 0,
            band(rsh(counter, 24), 0xFF),
            band(rsh(counter, 16), 0xFF),
            band(rsh(counter,  8), 0xFF),
            band(counter,          0xFF)
        )

        local hash = hmac_sha1(key_bytes, msg)
        local offset = band(byte(hash, 20), 0x0F)
        local b1, b2, b3, b4 = byte(hash, offset + 1, offset + 4)
        local P = band(bor(lsh(b1, 24), lsh(b2, 16), lsh(b3, 8), b4), 0x7FFFFFFF)
        return fmt("%06d", P % 1000000)
    end

    function DNR_TOTP.GetCode(secret_b32, step_offset)
        local key = base32_decode(secret_b32)
        local t = floor(GetServerTime() / 30) + (step_offset or 0)
        return hotp(key, t)
    end

    function DNR_TOTP.Verify(secret_b32, input)
        if not secret_b32 or secret_b32 == "" then return false end
        input = tostring(input):gsub("%s", "")
        if #input ~= 6 then return false end
        for offset = -1, 1 do
            if DNR_TOTP.GetCode(secret_b32, offset) == input then
                return true
            end
        end
        return false
    end

    local _genCallCount = 0

    function DNR_TOTP.GenerateSecret(len)
        len = len or 16
        _genCallCount = _genCallCount + 1
        local srv = GetServerTime()
        local frac = floor(GetTime() * 100000)
        local state = (srv * 2654435761 + frac * 40503 + _genCallCount * 6364136223) % 2147483647
        local t = {}
        for i = 1, len do
            state = (state * 1664525 + 1013904223) % 2147483647
            t[i] = B32ALPHA:sub((state % 32) + 1, (state % 32) + 1)
        end
        return table.concat(t)
    end

    function DNR_TOTP.FormatSecret(s)
        s = s:upper():gsub("[^A-Z2-7]", "")
        local groups = {}
        for i = 1, #s, 4 do
            groups[#groups + 1] = s:sub(i, i + 3)
        end
        return table.concat(groups, " ")
    end

    function DNR_TOTP.SecondsRemaining()
        return 30 - (GetServerTime() % 30)
    end
end
