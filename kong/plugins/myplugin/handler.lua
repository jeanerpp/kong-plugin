local cjson = require "cjson"

-- Cache version counter: incremented on config change to invalidate all cached entries
local cache_version = 0

local plugin = {
  PRIORITY = 1000,
  VERSION = "0.1",
}


-- Executed every time a plugin config changes.
function plugin:configure(configs)
  kong.log.notice("configure handler, got ", (configs and #configs or 0), " configs")

  if configs == nil then
    return
  end

  -- Increment cache version to invalidate all cached responses
  cache_version = cache_version + 1
  kong.log.notice("Plugin config changed, cache version now: ", cache_version)
end

local function check_remote_auth(plugin_conf)
  local http = require "resty.http"
  local httpc = http.new()
  httpc:set_timeout(5000)

  local auth_server_url = plugin_conf.remote_auth_server
  local request_header_name = plugin_conf.request_header_name
  local original_header_value = kong.request.get_header(request_header_name)
  kong.log.info("Request to auth server: ", auth_server_url,
                " with header: ", request_header_name, " = ", original_header_value)
  local res, err = httpc:request_uri(auth_server_url, {
    method = "GET",
    headers = {
      [request_header_name] = original_header_value
    }
  })

  if not res then
    kong.log.err("Failed to call auth server: ", err)
    return nil
  end

  if res.status == 200 then
    local body = cjson.decode(res.body)
    local token = body.token
    kong.log.info("Authentication successful: ", auth_server_url, " token: ", token)
    return token
  else
    kong.log.warn("Authentication failed: ", auth_server_url, " status: ", res.status)
    return nil
  end
end

function plugin:access(plugin_conf)
  -- Only cache GET and HEAD requests
  if ngx.var.request_method ~= "GET" and ngx.var.request_method ~= "HEAD" then
    kong.log.info("Skipping cache for ", ngx.var.request_method, " request")
    local auth_token = check_remote_auth(plugin_conf)

    if not auth_token then
      return kong.response.exit(401, "Authentication failed")
    end

    kong.service.request.set_header(plugin_conf.auth_header_name, "Bearer " .. auth_token)
    return
  end

  local cache_key = "myplugin:resp:v" .. cache_version .. ":" .. ngx.var.host .. ngx.var.request_uri
  local cached_str, err = kong.cache:get(cache_key)

  if cached_str then
    local cached = cjson.decode(cached_str)
    -- Manual TTL check: expire if past the stored deadline
    if not cached.expires_at or ngx.now() >= cached.expires_at then
      kong.log.info("Response cache expired for: ", cache_key)
      kong.cache:invalidate(cache_key)
    else
      kong.log.info("Response cache hit for: ", cache_key)
      local headers = cached.headers or {}
      headers["content-length"] = nil
      headers["transfer-encoding"] = nil
      headers["connection"] = nil
      headers["X-Cache-Status"] = "HIT"
      return kong.response.exit(cached.status, cached.body, headers)
    end
  end

  kong.log.info("Response cache miss for: ", cache_key)
  local auth_token = check_remote_auth(plugin_conf)

  if not auth_token then
    return kong.response.exit(401, "Authentication failed")
  end

  kong.service.request.set_header(plugin_conf.auth_header_name, "Bearer " .. auth_token)
  kong.ctx.plugin.cache_key = cache_key
  kong.ctx.plugin.cache_ttl = plugin_conf.ttl
end


function plugin:header_filter(plugin_conf)
  if kong.ctx.plugin.cache_key then
    local headers = kong.response.get_headers()
    local status = kong.response.get_status()
    headers["content-length"] = nil
    headers["transfer-encoding"] = nil
    headers["connection"] = nil
    kong.ctx.plugin.response_headers = headers
    kong.ctx.plugin.response_status = status

    -- HEAD requests have no body; cache immediately here
    if kong.request.get_method() == "HEAD" then
      local cache_key = kong.ctx.plugin.cache_key
      local ttl = kong.ctx.plugin.cache_ttl
      local cache_value = cjson.encode({
        status = status,
        body = "",
        headers = headers,
        expires_at = ngx.now() + ttl,
      })
      kong.cache:safe_set(cache_key, cache_value, ttl)
      kong.log.info("Cached HEAD response for: ", cache_key, " status: ", status, " ttl: ", ttl)
      kong.ctx.plugin.cache_key = nil
    end
  end
end


function plugin:body_filter(plugin_conf)
  if kong.ctx.plugin.cache_key then
    local chunk = ngx.arg[1]
    local eof = ngx.arg[2]
    kong.log.info("Body filter chunk: ", chunk and #chunk or "nil", " eof: ", eof)
    
    local body_chunks = kong.ctx.plugin.body_chunks or {}
    if chunk and chunk ~= "" then
      table.insert(body_chunks, chunk)
    end
    kong.ctx.plugin.body_chunks = body_chunks
    
    if eof then
      kong.log.info("Body filter EOF reached")
      local full_body = table.concat(body_chunks)
      local cache_key = kong.ctx.plugin.cache_key
      local ttl = kong.ctx.plugin.cache_ttl
      local status = kong.ctx.plugin.response_status
      local headers = kong.ctx.plugin.response_headers
      
      local cache_value = cjson.encode({
        status = status,
        body = full_body,
        headers = headers,
        expires_at = ngx.now() + ttl,
      })
      kong.cache:safe_set(cache_key, cache_value, ttl)
      kong.log.info("Cached response for: ", cache_key, " status: ", status, " ttl: ", ttl)
    end
  end
end

return plugin
