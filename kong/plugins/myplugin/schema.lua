local typedefs = require "kong.db.schema.typedefs"

local PLUGIN_NAME = "myplugin"

local schema = {
  name = PLUGIN_NAME,
  fields = {
    { consumer = typedefs.no_consumer },
    { protocols = typedefs.protocols_http },
    { config = {
        type = "record",
        fields = {
          { remote_auth_server = typedefs.url {
            required = true } },
          { request_header_name = typedefs.header_name {
            required = true } },
          { ttl = {
              type = "integer",
              default = 10,
              required = true,
              gt = 0, } },
          -- Header name for forwarding the JWT auth token to upstream
          { auth_header_name = typedefs.header_name {
            default = "Authorization",
            required = true } },
        },
        entity_checks = {},
      },
    },
  },
}

return schema
