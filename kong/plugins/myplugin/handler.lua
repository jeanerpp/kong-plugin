-- If you're not sure your plugin is executing, uncomment the line below and restart Kong
-- then it will throw an error which indicates the plugin is being loaded at least.

--assert(ngx.get_phase() == "timer", "The world is coming to an end!")

---------------------------------------------------------------------------------------------
-- In the code below, just remove the opening brackets; `[[` to enable a specific handler
--
-- The handlers are based on the OpenResty handlers, see the OpenResty docs for details
-- on when exactly they are invoked and what limitations each handler has.
---------------------------------------------------------------------------------------------



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

  -- your custom code here

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
  
  -- Call remote authentication server
  local auth_ok = check_remote_auth(plugin_conf)
  
  if not auth_ok then
    return kong.response.exit(401, "Authentication failed")
  end
  
end --]]

-- Function to check remote authentication
function check_remote_auth(plugin_conf)
  local http = require "resty.http"
  local httpc = http.new()
  
  -- Set timeout for the request
  httpc:set_timeout(5000)  -- 5 seconds
  
  -- Make request to remote auth server
  local auth_server_url = plugin_conf.remote_auth_server
  local original_header_value = kong.request.get_header(plugin_conf.request_header_name)
  local res, err = httpc:request_uri(auth_server_url, {
    method = "GET",
    headers = {
      [plugin_conf.request_header_name] = original_header_value
    }
  })
  
  if not res then
    kong.log.err("Failed to call auth server: ", err)
    return false
  end
  
  -- Check if auth server responded with 200 OK
  if res.status == 200 then
    kong.log.info("Authentication successful: ", auth_server_url)
    return true
  else
    kong.log.warn("Authentication failed: ", auth_server_url, " status: ", res.status)
    return false
  end
end


-- runs in the 'header_filter_by_lua_block'
function plugin:header_filter(plugin_conf)

end --]]


--[[ runs in the 'body_filter_by_lua_block'
function plugin:body_filter(plugin_conf)

  -- your custom code here
  kong.log.debug("saying hi from the 'body_filter' handler")

end --]]


--[[ runs in the 'log_by_lua_block'
function plugin:log(plugin_conf)

  -- your custom code here
  kong.log.debug("saying hi from the 'log' handler")

end --]]


-- return our plugin object
return plugin
