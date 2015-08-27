local ngx_var      = ngx.var
local ngx_header   = ngx.header
local concat       = table.concat
local hmac         = ngx.hmac_sha1
local time         = ngx.time
local http_time    = ngx.http_time
local type         = type
local setmetatable = setmetatable
local aes          = require "resty.aes"
local ffi          = require "ffi"
local ffi_cdef     = ffi.cdef
local ffi_new      = ffi.new
local ffi_str      = ffi.string
local ffi_typeof   = ffi.typeof
local C            = ffi.C

local CIPHER_MODES = {
    ecb    = "ecb",
    cbc    = "cbc",
    cfb1   = "cfb1",
    cfb8   = "cfb8",
    cfb128 = "cfb128",
    ofb    = "ofb",
    ctr    = "ctr"
}

local CIPHER_SIZES = {
    ["128"] = 128,
    ["192"] = 192,
    ["256"] = 256
}

ffi_cdef[[
typedef unsigned char u_char;
int RAND_pseudo_bytes(u_char *buf, int num);
]]

local t = ffi_typeof("uint8_t[?]")

local function random(len)
    local s = ffi_new(t, len)
    C.RAND_pseudo_bytes(s, len)
    return ffi_str(s, len)
end

local function enabled(val)
    if val == nil then return nil end
    return val == true or (val == "1" or val == "true" or val == "on")
end

local function setcookie(session, value, expires)
    local c = session.cookie
    local cookie = { session.name, "=", value or "" }
    local domain = c.domain
    if expires then
        cookie[#cookie + 1] = "; Expires=Thu, 01 Jan 1970 00:00:01 GMT; Max-Age=0"
    elseif c.persistent then
        cookie[#cookie + 1] = "; Expires="
        cookie[#cookie + 1] = http_time(session.expires)
    end
    if domain and domain ~= "localhost" and domain ~= "" then
        cookie[#cookie + 1] = "; Domain="
        cookie[#cookie + 1] = domain
    end
    cookie[#cookie + 1] = "; Path="
    cookie[#cookie + 1] = c.path or "/"
    if c.secure then
        cookie[#cookie + 1] = "; Secure"
    end
    if c.httponly then
        cookie[#cookie + 1] = "; HttpOnly"
    end
    local needle = concat(cookie, nil, 1, 2)
    cookie = concat(cookie)
    local cookies = ngx_header["Set-Cookie"]
    local t = type(cookies)
    if t == "table" then
        local found = false
        for i, c in ipairs(cookies) do
            if c:find(needle, 1, true) == 1 then
                cookies[i] = cookie
                found = true
                break
            end
        end
        if not found then
            cookies[#cookies + 1] = cookie
        end
    elseif t == "string" and cookies:find(needle, 1, true) ~= 1  then
        cookies = { cookies, cookie }
    else
        cookies = cookie
    end
    ngx_header["Set-Cookie"] = cookies
end

local function save(session, close)
    session.expires = time() + session.cookie.lifetime
    local i, e, c, s = session.id, session.expires, session.cipher, session.storage
    local k = hmac(session.secret, i .. e)
    local d = session.serializer.encode(session.data)
    local h = hmac(k, concat{ i, e, d, session.key })
    local a = aes:new(k, i, aes.cipher(c.size, c.mode), c.hash, c.rounds)
    local cookie = s:save(i, e, a:encrypt(d), h, close)
    setcookie(session, cookie)
end

local function regenerate(session, flush)
    local i = session.present and session.id or nil
    session.id = random(session.identifier.length)
    if flush then
        if i then
            session.storage.destroy(i);
        end
        session.data = {}
    end
end

local persistent = enabled(ngx_var.session_cookie_persistent or false)
local defaults = {
    name       = ngx_var.session_name       or "session",
    storage    = ngx_var.session_storage    or "cookie",
    serializer = ngx_var.session_serializer or "json",
    cookie = {
        persistent = persistent,
        renew      = tonumber(ngx_var.session_cookie_renew)    or 600,
        lifetime   = tonumber(ngx_var.session_cookie_lifetime) or 3600,
        path       = ngx_var.session_cookie_path               or "/",
        domain     = ngx_var.session_cookie_domain,
        secure     = enabled(ngx_var.session_cookie_secure),
        httponly   = enabled(ngx_var.session_cookie_httponly   or true)
    }, check = {
        ssi    = enabled(ngx_var.session_check_ssi    or persistent == false),
        ua     = enabled(ngx_var.session_check_ua     or true),
        scheme = enabled(ngx_var.session_check_scheme or true),
        addr   = enabled(ngx_var.session_check_addr   or false)
    }, cipher = {
        size   = CIPHER_SIZES[ngx_var.session_cipher_size] or 256,
        mode   = CIPHER_MODES[ngx_var.session_cipher_mode] or "cbc",
        hash   = aes.hash[ngx_var.session_cipher_hash]     or aes.hash.sha512,
        rounds = tonumber(ngx_var.session_cipher_rounds)   or 1
    }, identifier = {
        length  = tonumber(ngx_var.session_identifier_length) or 16
    }
}
defaults.secret = ngx_var.session_secret or random(defaults.cipher.size / 8)

local session = {
    _VERSION = "1.8-dev"
}

session.__index = session

function session.new(opts)
    if getmetatable(opts) == session then
        return opts
    end
    local z = defaults
    local y = opts or z
    local a, b = y.cookie     or z.cookie,     z.cookie
    local c, d = y.check      or z.check,      z.check
    local e, f = y.cipher     or z.cipher,     z.cipher
    local g, h = y.identifier or z.identifier, z.identifier
    local o, s = pcall(require, "resty.session.storage." .. (y.storage or z.storage))
    if not o then
        s = require "resty.session.storage.cookie"
    end
    local o, x = pcall(require, "resty.session.serializers." .. (y.serializer or z.serializer))
    if not o then
        x = require "resty.session.serializers.json"
    end
    return setmetatable({
        name       = y.name    or z.name,
        storage    = s.new(),
        serializer = x,
        data       = y.data    or {},
        secret     = y.secret  or z.secret,
        present    = false,
        opened     = false,
        started    = false,
        destroyed  = false,
        cookie = {
            persistent = a.persistent or b.persistent,
            renew      = a.renew      or b.renew,
            lifetime   = a.lifetime   or b.lifetime,
            path       = a.path       or b.path,
            domain     = a.domain     or b.domain,
            secure     = a.secure     or b.secure,
            httponly   = a.httponly   or b.httponly
        }, check = {
            ssi        = c.ssi        or d.ssi,
            ua         = c.ua         or d.ua,
            scheme     = c.scheme     or d.scheme,
            addr       = c.addr       or d.addr
        }, cipher = {
            size       = e.size       or f.size,
            mode       = e.mode       or f.mode,
            hash       = e.hash       or f.hash,
            rounds     = e.rounds     or f.rounds
        }, identifier = {
            length     = g.length     or h.length
        }
    }, session)
end

function session.open(opts)
    local self = opts
    if getmetatable(self) == session then
        if self.opened then
            return self, self.present
        end
    else
        self = session.new(opts)
    end
    local scheme = ngx_header["X-Forwarded-Proto"]
    if self.cookie.secure == nil then
        if scheme then
            self.cookie.secure = scheme == "https"
        else
            self.cookie.secure = ngx_var.https == "on"
        end
    end
    scheme = self.check.scheme and (scheme or ngx_var.scheme or "") or ""
    local addr = ""
    if self.check.addr then
        addr = ngx_header["CF-Connecting-IP"] or
               ngx_header["Fastly-Client-IP"] or
               ngx_header["Incap-Client-IP"]  or
               ngx_header["X-Real-IP"]
        if not addr then
            addr = ngx_header["X-Forwarded-For"]
            if addr then
                -- We shouldn't really get the left-most address, because of spoofing,
                -- but this is better handled with a module, like nginx realip module,
                -- anyway (see also: http://goo.gl/Z6u2oR).
                local s = (addr:find(',', 1, true))
                if s then
                    addr = addr:sub(1, s - 1)
                end
            else
                addr = ngx_var.remote_addr
            end
        end
    end
    self.key = concat{
        self.check.ssi and (ngx_var.ssl_session_id  or "") or "",
        self.check.ua  and (ngx_var.http_user_agent or "") or "",
        addr,
        scheme
    }
    local cookie = ngx_var["cookie_" .. self.name]
    if cookie then
        local i, e, d, h = self.storage:open(cookie, self.cookie.lifetime)
        if i and e and e > time() and d and h then
            self.id = i
            self.expires = e
            local c = self.cipher
            local k = hmac(self.secret, self.id .. e)
            local a = aes:new(k, i, aes.cipher(c.size, c.mode), c.hash, c.rounds)
            d = a:decrypt(d)
            if d and hmac(k, concat{ i, e, d, self.key }) == h then
                self.data = self.serializer.decode(d)
                self.present = true
            end
        end
    end
    if not self.present then
        regenerate(self)
    end
    if type(self.data) ~= "table" then self.data = {} end
    self.opened = true
    return self, self.present
end

function session.start(opts)
    if getmetatable(opts) == session and opts.started then
        return opts, opts.present
    end
    local self, present = session.open(opts)
    if present then
        if self.storage.start then
            self.storage:start(self.id)
        end
        if self.expires - time() < self.cookie.renew then
            save(self)
        end
    else
        save(self)
    end
    self.started = true
    return self, present
end

function session:regenerate(flush)
    regenerate(self, flush)
    return save(self)
end

function session:save()
    return save(self, true)
end

function session:destroy()
    if self.storage.destroy then
        self.storage:destroy(self.id)
    end
    self.data = {}
    self.present = false
    self.opened = false
    self.started = false
    self.destroyed = true
    return setcookie(self, "", true)
end

return session