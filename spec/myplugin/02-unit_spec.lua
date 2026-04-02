-- unit tests for myplugin with GET and HEAD request methods

local PLUGIN_NAME = "myplugin"


for _, method in ipairs({"GET", "HEAD"}) do

describe(PLUGIN_NAME .. ": (unit) [" .. method .. "]", function()

  local plugin
  local exit_status, exit_body, exit_headers
  local set_header_name, set_header_value
  local cache_store = {}
  local ctx_plugin = {}

  setup(function()
    _G.ngx = {
      var = {
        scheme = "http",
        host = "test.example.com",
        request_uri = "/test",
        request_method = method,
      },
      arg = { nil, nil },
      now = function() return 1640995200 end,
    }

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
          return method
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

    it("calls remote auth and sets Authorization header on cache miss", function()
      local config = {
        request_header_name = "X-My-Header",
        remote_auth_server = "http://auth-server:80",
        auth_header_name = "Authorization",
        ttl = 10,
      }

      plugin:access(config)

      assert.equal("Authorization", set_header_name)
      assert.equal("Bearer mock-jwt-token", set_header_value)
      assert.is_not_nil(kong.ctx.plugin.cache_key)
      assert.equal(10, kong.ctx.plugin.cache_ttl)
    end)


    it("returns cached response on cache hit (not expired)", function()
      local cjson = require "cjson"
      local config = {
        request_header_name = "X-My-Header",
        remote_auth_server = "http://auth-server:80",
        auth_header_name = "Authorization",
        ttl = 10,
      }

      local cache_key = "myplugin:resp:v0:test.example.com/test"
      cache_store[cache_key] = cjson.encode({
        status = 200,
        body = "cached body",
        headers = { ["content-type"] = "text/plain" },
        expires_at = ngx.now() + 10,
      })

      plugin:access(config)

      assert.equal(200, exit_status)
      assert.equal("cached body", exit_body)
      assert.equal("HIT", exit_headers["X-Cache-Status"])
      assert.is_nil(set_header_name)
    end)


    it("invalidates cache when entry has expired", function()
      local cjson = require "cjson"
      local config = {
        request_header_name = "X-My-Header",
        remote_auth_server = "http://auth-server:80",
        auth_header_name = "Authorization",
        ttl = 10,
      }

      local cache_key = "myplugin:resp:v0:test.example.com/test"
      cache_store[cache_key] = cjson.encode({
        status = 200,
        body = "stale body",
        headers = { ["content-type"] = "text/plain" },
        expires_at = ngx.now() - 1,
      })

      plugin:access(config)

      assert.is_nil(cache_store[cache_key])
      assert.equal("Authorization", set_header_name)
      assert.equal("Bearer mock-jwt-token", set_header_value)
    end)


    it("invalidates cache when expires_at is missing", function()
      local cjson = require "cjson"
      local config = {
        request_header_name = "X-My-Header",
        remote_auth_server = "http://auth-server:80",
        auth_header_name = "Authorization",
        ttl = 10,
      }

      local cache_key = "myplugin:resp:v0:test.example.com/test"
      cache_store[cache_key] = cjson.encode({
        status = 200,
        body = "old cached body",
        headers = { ["content-type"] = "text/plain" },
      })

      plugin:access(config)

      assert.is_nil(cache_store[cache_key])
      assert.equal("Authorization", set_header_name)
      assert.equal("Bearer mock-jwt-token", set_header_value)
    end)


    it("returns 401 when auth fails", function()
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
      local config = {
        request_header_name = "X-My-Header",
        remote_auth_server = "http://auth-server:80",
        auth_header_name = "Authorization",
        ttl = 10,
      }

      plugin:access(config)

      assert.equal(401, exit_status)
      assert.is_nil(exit_headers)
      assert.equal("Authentication failed", exit_body)
    end)


    it("returns 401 when auth server has no reply", function()
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
      assert.is_nil(set_header_name)
    end)

  end)


  -- configure phase tests only need to run once (not method-specific)
  if method == "GET" then
    describe("configure phase", function()

      before_each(function()
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
        package.loaded["kong.plugins." .. PLUGIN_NAME .. ".handler"] = nil
        plugin = require("kong.plugins." .. PLUGIN_NAME .. ".handler")
      end)

      it("increments cache version when configs are provided", function()
        local config = {
          request_header_name = "X-My-Header",
          remote_auth_server = "http://auth-server:80",
          auth_header_name = "Authorization",
          ttl = 10,
        }

        plugin:access(config)
        local cache_key_before = kong.ctx.plugin.cache_key

        plugin:configure({ config })
        ctx_plugin = {}
        kong.ctx.plugin = ctx_plugin

        plugin:access(config)
        local cache_key_after = kong.ctx.plugin.cache_key

        assert.is_not_nil(cache_key_before)
        assert.is_not_nil(cache_key_after)
        assert.are_not.equal(cache_key_before, cache_key_after)
      end)

      it("does nothing when configs is nil", function()
        local config = {
          request_header_name = "X-My-Header",
          remote_auth_server = "http://auth-server:80",
          auth_header_name = "Authorization",
          ttl = 10,
        }

        plugin:access(config)
        local cache_key_before = kong.ctx.plugin.cache_key

        plugin:configure(nil)
        ctx_plugin = {}
        kong.ctx.plugin = ctx_plugin

        plugin:access(config)
        local cache_key_after = kong.ctx.plugin.cache_key

        assert.is_not_nil(cache_key_before)
        assert.is_not_nil(cache_key_after)
        assert.equal(cache_key_before, cache_key_after)
      end)

    end)
  end


  describe("header_filter phase", function()

    it("captures response headers and status when cache_key is set", function()
      kong.ctx.plugin.cache_key = "myplugin:resp:v0:test.example.com/test"
      kong.ctx.plugin.cache_ttl = 10

      local config = {
        request_header_name = "X-My-Header",
        remote_auth_server = "http://auth-server:80",
        auth_header_name = "Authorization",
        ttl = 10,
      }

      plugin:header_filter(config)

      assert.is_not_nil(kong.ctx.plugin.response_headers)
      assert.equal(200, kong.ctx.plugin.response_status)
      assert.is_nil(kong.ctx.plugin.response_headers["content-length"])
      assert.is_nil(kong.ctx.plugin.response_headers["transfer-encoding"])
      assert.is_nil(kong.ctx.plugin.response_headers["connection"])
    end)


    it("skips when cache_key is not set", function()
      local config = {
        request_header_name = "X-My-Header",
        remote_auth_server = "http://auth-server:80",
        auth_header_name = "Authorization",
        ttl = 10,
      }

      plugin:header_filter(config)

      assert.is_nil(kong.ctx.plugin.response_headers)
      assert.is_nil(kong.ctx.plugin.response_status)
    end)

  end)


  describe("body_filter phase", function()

    it("accumulates body chunks and caches on EOF", function()
      kong.ctx.plugin.cache_key = "myplugin:resp:v0:test.example.com/test"
      kong.ctx.plugin.cache_ttl = 10
      kong.ctx.plugin.response_status = 200
      kong.ctx.plugin.response_headers = { ["content-type"] = "text/plain" }

      local config = {
        request_header_name = "X-My-Header",
        remote_auth_server = "http://auth-server:80",
        auth_header_name = "Authorization",
        ttl = 10,
      }

      ngx.arg = { "Hello ", false }
      plugin:body_filter(config)
      assert.equal(1, #kong.ctx.plugin.body_chunks)

      local cached = cache_store["myplugin:resp:v0:test.example.com/test"]
      assert.is_nil(cached)

      ngx.arg = { "World", true }
      plugin:body_filter(config)

      cached = cache_store["myplugin:resp:v0:test.example.com/test"]
      assert.is_not_nil(cached)

      local cjson = require "cjson"
      local decoded = cjson.decode(cached)
      assert.equal(200, decoded.status)
      assert.equal("Hello World", decoded.body)
    end)


    it("skips when cache_key is not set", function()
      local config = {
        request_header_name = "X-My-Header",
        remote_auth_server = "http://auth-server:80",
        auth_header_name = "Authorization",
        ttl = 10,
      }

      ngx.arg = { "some data", true }
      plugin:body_filter(config)

      assert.is_same({}, cache_store)
    end)

  end)

end)

end -- for method
