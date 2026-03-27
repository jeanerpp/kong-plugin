local helpers = require "spec.helpers"


local PLUGIN_NAME = "myplugin"

-- Resolve the auth server hostname from the pongo network
local PONGO_NETWORK = os.getenv("PONGO_NETWORK") or "pongo-test-network"
local AUTH_SERVER = "http://" .. PONGO_NETWORK .. "-nginx-remote-ok." .. PONGO_NETWORK


for _, strategy in helpers.all_strategies() do if strategy ~= "cassandra" then
  describe(PLUGIN_NAME .. ": (access) [#" .. strategy .. "]", function()
    local client

    lazy_setup(function()

      local bp = helpers.get_db_utils(strategy == "off" and "postgres" or strategy, nil, { PLUGIN_NAME })

      -- Inject a test route. No need to create a service, there is a default
      -- service which will echo the request.
      local route1 = bp.routes:insert({
        hosts = { "test1.com" },
      })
      -- add the plugin to test to the route we created
      bp.plugins:insert {
        name = PLUGIN_NAME,
        route = { id = route1.id },
        config = {
          request_header_name = "Host",
          remote_auth_server = AUTH_SERVER,
          auth_header_name = "Authorization",
          ttl = 10,
        },
      }

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
            host = "test1.com"
          }
        })
        assert.response(r1).has.status(200)

        -- Second request: cache hit (should return same response)
        local client2 = helpers.proxy_client()
        local r2 = client2:get("/request", {
          headers = {
            host = "test1.com"
          }
        })
        assert.response(r2).has.status(200)
        client2:close()
      end)
    end)

  end)

end end
