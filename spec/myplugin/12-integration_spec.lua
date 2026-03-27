local helpers = require "spec.helpers"


local PLUGIN_NAME = "myplugin"

-- nginx-remote-to accepts TCP connections but never responds (timeout simulation)
local PONGO_NETWORK = os.getenv("PONGO_NETWORK") or "pongo-test-network"
local AUTH_SERVER_TO = "http://" .. PONGO_NETWORK .. "-nginx-remote-to." .. PONGO_NETWORK


for _, strategy in helpers.all_strategies() do if strategy ~= "cassandra" then
  describe(PLUGIN_NAME .. ": (auth timeout) [#" .. strategy .. "]", function()
    local client

    lazy_setup(function()

      local bp = helpers.get_db_utils(strategy == "off" and "postgres" or strategy, nil, { PLUGIN_NAME })

      local route1 = bp.routes:insert({
        hosts = { "test-to.com" },
      })
      bp.plugins:insert {
        name = PLUGIN_NAME,
        route = { id = route1.id },
        config = {
          request_header_name = "Host",
          remote_auth_server = AUTH_SERVER_TO,
          auth_header_name = "Authorization",
          ttl = 10,
        },
      }

      assert(helpers.start_kong({
        database   = strategy,
        nginx_conf = "spec/fixtures/custom_nginx.template",
        plugins = "bundled," .. PLUGIN_NAME,
        declarative_config = strategy == "off" and helpers.make_yaml_file() or nil,
      }))
    end)

    lazy_teardown(function()
      helpers.stop_kong(nil, true)
    end)

    before_each(function()
      -- Use a longer timeout since the auth server hangs for 5s before our plugin times out
      client = helpers.proxy_client(10000)
    end)

    after_each(function()
      if client then client:close() end
    end)



    describe("request with hanging auth server", function()
      it("returns 401 when auth server times out", function()
        local r = client:get("/request", {
          headers = {
            host = "test-to.com"
          }
        })
        assert.response(r).has.status(401)
      end)
    end)

  end)

end end
