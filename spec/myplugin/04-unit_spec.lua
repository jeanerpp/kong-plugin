-- unit tests for myplugin with non GET/HEAD request method

local PLUGIN_NAME = "myplugin"


describe(PLUGIN_NAME .. ": (unit)", function()

  local plugin
  local exit_status, exit_body, exit_headers
  local set_header_name, set_header_value
  local cache_store = {}
  local ctx_plugin = {}

  setup(function()
    -- Mock ngx global
    _G.ngx = {
      var = {
        scheme = "http",
        host = "test.example.com",
        request_uri = "/test",
        request_method = "POST",
      },
      arg = { nil, nil },
      now = function() return 1640995200 end,  -- Fixed timestamp for testing
    }

    -- Mock kong global
    _G.kong = {
      log = {
        inspect = function() end,
        info = function() end,
        notice = function() end,
        warn = function() end,
        err = function() end,
        debug = function() end,
      },
      cache = {
        get = function(self, key, opts, cb)
          if cache_store[key] then
            return cache_store[key], nil
          end
          if cb then
            local val = cb()
            return val, nil
          end
          return nil, nil
        end,
        safe_set = function(self, key, val, ttl)
          cache_store[key] = val
        end,
        invalidate = function(self, key)
          cache_store[key] = nil
        end,
      },
      ctx = {
        plugin = ctx_plugin,
      },
      request = {
        get_header = function(name)
          return "test-header-value"
        end,
        get_method = function()
          return "POST"
        end,
      },
      response = {
        exit = function(status, body, headers)
          exit_status = status
          exit_body = body
          exit_headers = headers
        end,
        get_headers = function()
          return { ["content-type"] = "text/plain", ["x-custom"] = "value" }
        end,
        get_status = function()
          return 200
        end,
      },
      service = {
        request = {
          set_header = function(name, val)
            set_header_name = name
            set_header_value = val
          end,
        },
      },
    }

    -- Mock resty.http for check_remote_auth
    package.loaded["resty.http"] = {
      new = function()
        return {
          set_timeout = function() end,
          request_uri = function(self, url, opts)
            return {
              status = 200,
              body = '{"token":"mock-jwt-token"}',
            }, nil
          end,
        }
      end,
    }

    -- Load the plugin
    plugin = require("kong.plugins." .. PLUGIN_NAME .. ".handler")
  end)


  before_each(function()
    exit_status = nil
    exit_body = nil
    exit_headers = nil
    set_header_name = nil
    set_header_value = nil
    cache_store = {}
    ctx_plugin = {}
    kong.ctx.plugin = ctx_plugin
  end)


  describe("access phase", function()

    it("calls remote auth and sets Authorization header without setting cache key", function()
      local config = {
        request_header_name = "X-My-Header",
        remote_auth_server = "http://auth-server:80",
        auth_header_name = "Authorization",
        ttl = 10,
      }

      plugin:access(config)

      -- Should have set the auth header on the upstream request
      assert.equal("Authorization", set_header_name)
      assert.equal("Bearer mock-jwt-token", set_header_value)

      -- Should not have stored cache_key in context for later phases
      assert.is_nil(kong.ctx.plugin.cache_key)
    end)


    it("returns 401 when auth fails", function()
      -- Override resty.http mock to return 401
      package.loaded["resty.http"] = {
        new = function()
          return {
            set_timeout = function() end,
            request_uri = function(self, url, opts)
              return { status = 401, body = "Unauthorized" }, nil
            end,
          }
        end,
      }
      -- Force re-require of handler to pick up new mock
      -- Instead, we directly test check_remote_auth behavior via access
      local config = {
        request_header_name = "X-My-Header",
        remote_auth_server = "http://auth-server:80",
        auth_header_name = "Authorization",
        ttl = 10,
      }

      plugin:access(config)

      assert.equal(401, exit_status)
      assert.equal("Authentication failed", exit_body)
    end)


    it("returns 401 when auth server has no reply", function()
      -- Override resty.http mock to return nil (connection error / timeout)
      package.loaded["resty.http"] = {
        new = function()
          return {
            set_timeout = function() end,
            request_uri = function(self, url, opts)
              return nil, "connection refused"
            end,
          }
        end,
      }

      local config = {
        request_header_name = "X-My-Header",
        remote_auth_server = "http://auth-server:80",
        auth_header_name = "Authorization",
        ttl = 10,
      }

      plugin:access(config)

      assert.equal(401, exit_status)
      assert.equal("Authentication failed", exit_body)
      -- Should NOT have set any auth header
      assert.is_nil(set_header_name)
    end)

  end)

end)
