local helpers = require "spec.helpers"


local PLUGIN_NAME = "myplugin"

-- nginx-remote-nok returns 500 Internal Server Error
local PONGO_NETWORK = os.getenv("PONGO_NETWORK") or "pongo-test-network"
local AUTH_SERVER_NOK = "http://" .. PONGO_NETWORK .. "-nginx-remote-nok." .. PONGO_NETWORK


for _, strategy in helpers.all_strategies() do if strategy ~= "cassandra" then
  describe(PLUGIN_NAME .. ": (auth failure) [#" .. strategy .. "]", function()
    local client

    lazy_setup(function()

      local bp = helpers.get_db_utils(strategy == "off" and "postgres" or strategy, nil, { PLUGIN_NAME })

      local route1 = bp.routes:insert({
        hosts = { "test-nok.com" },
      })
      bp.plugins:insert {
        name = PLUGIN_NAME,
        route = { id = route1.id },
        config = {
          request_header_name = "Host",
          remote_auth_server = AUTH_SERVER_NOK,
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
      client = helpers.proxy_client()
    end)

    after_each(function()
      if client then client:close() end
    end)



    describe("request with failing auth server", function()
      it("returns 401 when auth server responds with 500", function()
        local r = client:get("/request", {
          headers = {
            host = "test-nok.com"
          }
        })
        assert.response(r).has.status(401)
      end)
    end)

  end)

end end
