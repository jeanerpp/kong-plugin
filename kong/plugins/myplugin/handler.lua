-- If you're not sure your plugin is executing, uncomment the line below and restart Kong
-- then it will throw an error which indicates the plugin is being loaded at least.

--assert(ngx.get_phase() == "timer", "The world is coming to an end!")

---------------------------------------------------------------------------------------------
-- In the code below, just remove the opening brackets; `[[` to enable a specific handler
--
-- The handlers are based on the OpenResty handlers, see the OpenResty docs for details
-- on when exactly they are invoked and what limitations each handler has.
---------------------------------------------------------------------------------------------



local cjson = require "cjson"

-- Cache version counter: incremented on config change to invalidate all cached entries
local cache_version = 0

local plugin = {
  PRIORITY = 1000, -- set the plugin priority, which determines plugin execution order
  VERSION = "0.1", -- version in X.Y.Z format. Check hybrid-mode compatibility requirements.
}



-- do initialization here, any module level code runs in the 'init_by_lua_block',
-- before worker processes are forked. So anything you add here will run once,
-- but be available in all workers.



-- handles more initialization, but AFTER the worker process has been forked/created.
-- It runs in the 'init_worker_by_lua_block'
function plugin:init_worker()

  -- your custom code here
  kong.log.debug("saying hi from the 'init_worker' handler")

end --]]


---[[ Executed every time a plugin config changes.
-- This can run in the `init_worker` or `timer` phase.
-- @param configs table|nil A table with all the plugin configs of this plugin type.
function plugin:configure(configs)
  kong.log.notice("saying hi from the 'configure' handler, got ", (configs and #configs or 0)," configs")

  if configs == nil then
    return -- no configs, nothing to do
  end

  -- Increment cache version to invalidate all cached responses
  cache_version = cache_version + 1
  kong.log.notice("Plugin config changed, cache version now: ", cache_version)

end --]]


--[[ runs in the 'ssl_certificate_by_lua_block'
-- IMPORTANT: during the `certificate` phase neither `route`, `service`, nor `consumer`
-- will have been identified, hence this handler will only be executed if the plugin is
-- configured as a global plugin!
function plugin:certificate(plugin_conf)

  -- your custom code here
  kong.log.debug("saying hi from the 'certificate' handler")

end --]]



--[[ runs in the 'rewrite_by_lua_block'
-- IMPORTANT: during the `rewrite` phase neither `route`, `service`, nor `consumer`
-- will have been identified, hence this handler will only be executed if the plugin is
-- configured as a global plugin!
function plugin:rewrite(plugin_conf)

  -- your custom code here
  kong.log.debug("saying hi from the 'rewrite' handler")

end --]]



-- runs in the 'access_by_lua_block'
function plugin:access(plugin_conf)

  -- your custom code here
  kong.log.inspect(plugin_conf)   -- check the logs for a pretty-printed config!
  
  -- Only cache GET and HEAD requests
  if ngx.var.request_method ~= "GET" and ngx.var.request_method ~= "HEAD" then
    kong.log.info("Skipping cache for ", ngx.var.request_method, " request")
    -- Call remote authentication server for non-cacheable requests
    local auth_token = check_remote_auth(plugin_conf)
    
    if not auth_token then
      return kong.response.exit(401, "Authentication failed")
    end
    
    kong.service.request.set_header(plugin_conf.auth_header_name, "Bearer " .. auth_token)
    return
  end
  
  -- Use the full request URL as cache key
  local cache_key = "myplugin:resp:v" .. cache_version .. ":" .. ngx.var.host .. ngx.var.request_uri
  
  -- Check response cache first (shared across all workers)
  local cached_str, err = kong.cache:get(cache_key)
  
  if cached_str then
    local cached = cjson.decode(cached_str)
    -- Manual TTL check: expire if past the stored deadline
    if not cached.expires_at or ngx.now() >= cached.expires_at then
      kong.log.info("Response cache expired for: ", cache_key)
      kong.cache:invalidate(cache_key)
    else
      kong.log.info("Response cache hit for: ", cache_key)
      -- Remove headers that Kong should recompute for this response
      local headers = cached.headers or {}
      headers["content-length"] = nil
      headers["transfer-encoding"] = nil
      headers["connection"] = nil
      headers["X-Cache-Status"] = "HIT"
      return kong.response.exit(cached.status, cached.body, headers)
    end
  end
  
  kong.log.info("Response cache miss for: ", cache_key)
  
  -- Call remote authentication server
  local auth_token = check_remote_auth(plugin_conf)
  
  if not auth_token then
    return kong.response.exit(401, "Authentication failed")
  end

  kong.service.request.set_header(plugin_conf.auth_header_name, "Bearer " .. auth_token)

  -- Store cache key and TTL in context for later phases
  kong.ctx.plugin.cache_key = cache_key
  kong.ctx.plugin.cache_ttl = plugin_conf.ttl
  
end --]]

-- Function to check remote authentication
function check_remote_auth(plugin_conf)
  local http = require "resty.http"
  local httpc = http.new()
  local cjson = require "cjson"
  
  -- Set timeout for the request
  httpc:set_timeout(5000)  -- 5 seconds
  
  -- Make request to remote auth server
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
  
  -- Check if auth server responded with 200 OK
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


-- runs in the 'header_filter_by_lua_block'
function plugin:header_filter(plugin_conf)
  -- Capture response headers for caching
  if kong.ctx.plugin.cache_key then
    local headers = kong.response.get_headers()
    local status = kong.response.get_status()
    -- Remove hop-by-hop headers that should not be cached
    headers["content-length"] = nil
    headers["transfer-encoding"] = nil
    headers["connection"] = nil
    kong.ctx.plugin.response_headers = headers
    kong.ctx.plugin.response_status = status

    -- HEAD requests have no body, so body_filter won't be called.
    -- Cache immediately with an empty body.
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
      kong.ctx.plugin.cache_key = nil  -- prevent body_filter from caching again
    end
  end
end --]]


-- runs in the 'body_filter_by_lua_block'
function plugin:body_filter(plugin_conf)
  -- Accumulate response body chunks for caching
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
      
      -- Cache the full response (shared across all workers)
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
end --]]


--[[ runs in the 'log_by_lua_block'
function plugin:log(plugin_conf)

  -- your custom code here
  kong.log.debug("saying hi from the 'log' handler")

end --]]


-- return our plugin object
return plugin
