local typedefs = require "kong.db.schema.typedefs"


local PLUGIN_NAME = "myplugin"


local schema = {
  name = PLUGIN_NAME,
  fields = {
    -- the 'fields' array is the top-level entry with fields defined by Kong
    { consumer = typedefs.no_consumer },  -- this plugin cannot be configured on a consumer (typical for auth plugins)
    { protocols = typedefs.protocols_http },
    { config = {
        -- The 'config' record is the custom part of the plugin schema
        type = "record",
        fields = {
          { remote_auth_server = typedefs.url {
            required = true } },
          { request_header_name = typedefs.header_name {
            required = true } },
          { ttl = { -- self defined field
              type = "integer",
              default = 10,
              required = true,
              gt = 0, }}, -- adding a constraint for the value
          { auth_header_name = typedefs.header_name {
            -- the request head name for JWT auth token to upstream server
            default = "Authorization",
            required = true } },
        },
        entity_checks = {
        },
      },
    },
  },
}

return schema
