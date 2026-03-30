local helpers = require "spec.helpers"
local cjson = require "cjson"


local PLUGIN_NAME = "myplugin"

-- Resolve the auth server hostname from the pongo network
local PONGO_NETWORK = os.getenv("PONGO_NETWORK") or "pongo-test-network"
local AUTH_SERVER = "http://" .. PONGO_NETWORK .. "-nginx-remote-ok." .. PONGO_NETWORK


for _, strategy in helpers.all_strategies() do if strategy ~= "cassandra" then
  describe(PLUGIN_NAME .. ": (access) [#" .. strategy .. "]", function()
    local client
    local plugin_id  -- Save plugin ID for Admin API updates

    lazy_setup(function()

      local bp = helpers.get_db_utils(strategy == "off" and "postgres" or strategy, nil, { PLUGIN_NAME })

      -- Inject a test route. No need to create a service, there is a default
      -- service which will echo the request.
      local route1 = bp.routes:insert({
        hosts = { "test1.com", "test2.com", "test3.com" },
      })
      -- add the plugin to test to the route we created
      local plugin = bp.plugins:insert {
        name = PLUGIN_NAME,
        route = { id = route1.id },
        config = {
          request_header_name = "Host",
          remote_auth_server = AUTH_SERVER,
          auth_header_name = "Authorization",
          ttl = 10,
        },
      }
      plugin_id = plugin.id

      -- start kong
      assert(helpers.start_kong({
        -- set the strategy
        database   = strategy,
        -- use the custom test template to create a local mock server
        nginx_conf = "spec/fixtures/custom_nginx.template",
        -- make sure our plugin gets loaded
        plugins = "bundled," .. PLUGIN_NAME,
        -- write & load declarative config, only if 'strategy=off'
        declarative_config = strategy == "off" and helpers.make_yaml_file() or nil,
      }))
    end)

    lazy_teardown(function()
      helpers.stop_kong(nil, true)
    end)

    before_each(function()
      client = helpers.proxy_client()
    end)

    after_each(function()
      if client then client:close() end
    end)



    describe("request", function()
      it("authenticates and proxies request on cache miss", function()
        local r = client:get("/request", {
          headers = {
            host = "test1.com"
          }
        })
        -- validate that the request succeeded, response status 200
        assert.response(r).has.status(200)
        -- check that the Authorization header was set on the proxied request
        local header_value = assert.request(r).has.header("Authorization")
        assert.matches("^Bearer ", header_value)
      end)
    end)



    describe("caching", function()
      it("returns cached response on second request", function()
        -- First request: cache miss
        local r1 = client:get("/request", {
          headers = {
            host = "test2.com"
          }
        })
        assert.response(r1).has.status(200)
        -- check that the X-Cache-Status response header is not set (cache miss)
        assert.response(r1).has.no.header("X-Cache-Status")

        -- Second request: cache hit (should return same response)
        local r2 = client:get("/request", {
          headers = {
            host = "test2.com"
          }
        })
        assert.response(r2).has.status(200)
        -- check that the X-Cache-Status response header is set (cache hit)
        local cache_status = assert.response(r2).has.header("X-Cache-Status")
        assert.equal("HIT", cache_status)

      end)
    end)


    -- Cache invalidation via Admin API only works with a database
    if strategy ~= "off" then
      describe("cache invalidation", function()
        it("invalidates cache when plugin config changes", function()
          -- First request: cache miss with original config
          local r1 = client:get("/request", {
            headers = { host = "test3.com" }
          })
          assert.response(r1).has.status(200)
          assert.response(r1).has.no.header("X-Cache-Status")

          -- Second request: cache hit with same config
          local r2 = client:get("/request", {
            headers = { host = "test3.com" }
          })
          assert.response(r2).has.status(200)
          local cache_status2 = assert.response(r2).has.header("X-Cache-Status")
          assert.equal("HIT", cache_status2)

          -- Update plugin configuration via Admin API
          -- This triggers plugin:configure which increments cache_version
          local admin = helpers.admin_client()
          local res = admin:patch("/plugins/" .. plugin_id, {
            headers = { ["Content-Type"] = "application/json" },
            body = cjson.encode({
              config = {
                request_header_name = "X-My-Header",
                remote_auth_server = AUTH_SERVER,
                auth_header_name = "Authorization",
                ttl = 10,
              }
            })
          })
          assert.res_status(200, res)
          admin:close()

          -- Wait for Kong to reload the updated config
          helpers.wait_for_all_config_update()

          -- Third request: should be cache miss due to config change
          local client3 = helpers.proxy_client()
          local r3 = client3:get("/request", {
            headers = {
              host = "test3.com",
              ["X-My-Header"] = "test-value"
            }
          })
          assert.response(r3).has.status(200)
          assert.response(r3).has.no.header("X-Cache-Status")
          client3:close()

          -- Fourth request: cache hit with new config
          local client4 = helpers.proxy_client()
          local r4 = client4:get("/request", {
            headers = {
              host = "test3.com",
              ["X-My-Header"] = "test-value"
            }
          })
          assert.response(r4).has.status(200)
          local cache_status4 = assert.response(r4).has.header("X-Cache-Status")
          assert.equal("HIT", cache_status4)
          client4:close()
        end)
      end)
    end -- strategy ~= "off"

  end)

end end
