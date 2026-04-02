local PLUGIN_NAME = "myplugin"


-- helper function to validate data against a schema
local validate do
  local validate_entity = require("spec.helpers").validate_plugin_config_schema
  local plugin_schema = require("kong.plugins."..PLUGIN_NAME..".schema")

  function validate(data)
    return validate_entity(data, plugin_schema)
  end
end


describe(PLUGIN_NAME .. ": (schema)", function()


  it("accepts valid config with all required fields", function()
    local ok, err = validate({
        request_header_name = "X-My-Header",
        remote_auth_server = "http://auth-server:80",
      })
    assert.is_nil(err)
    assert.is_truthy(ok)
  end)


  it("rejects config missing request_header_name", function()
    local ok, err = validate({
        remote_auth_server = "http://auth-server:80",
      })
    assert.is_falsy(ok)
    assert.not_nil(err)
    assert.not_nil(err.config.request_header_name)
  end)


  it("rejects config missing remote_auth_server", function()
    local ok, err = validate({
        request_header_name = "X-My-Header",
      })
    assert.is_falsy(ok)
    assert.not_nil(err)
    assert.not_nil(err.config.remote_auth_server)
  end)


  it("uses default ttl of 10", function()
    local ok, err = validate({
        request_header_name = "X-My-Header",
        remote_auth_server = "http://auth-server:80",
      })
    assert.is_nil(err)
    assert.is_truthy(ok)
    assert.equal(10, ok.config.ttl)
  end)


  it("uses default auth_header_name of Authorization", function()
    local ok, err = validate({
        request_header_name = "X-My-Header",
        remote_auth_server = "http://auth-server:80",
      })
    assert.is_nil(err)
    assert.is_truthy(ok)
    assert.equal("Authorization", ok.config.auth_header_name)
  end)


  it("rejects ttl less than or equal to 0", function()
    local ok, err = validate({
        request_header_name = "X-My-Header",
        remote_auth_server = "http://auth-server:80",
        ttl = 0,
      })
    assert.is_falsy(ok)
    assert.not_nil(err)
  end)


  it("accepts custom ttl and auth_header_name", function()
    local ok, err = validate({
        request_header_name = "X-My-Header",
        remote_auth_server = "http://auth-server:80",
        ttl = 300,
        auth_header_name = "X-Auth-Token",
      })
    assert.is_nil(err)
    assert.is_truthy(ok)
    assert.equal(300, ok.config.ttl)
    assert.equal("X-Auth-Token", ok.config.auth_header_name)
  end)


end)
