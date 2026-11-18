require "base64"
require "json"
require "net/http"
require "openssl"
require "time"
require "uri"

APPLE_API = "https://api.appstoreconnect.apple.com"
APPLE_KEY_VARS = %w[MOEMEMOS_ASC_KEY_PATH MOEMEMOS_ASC_KEY_ID MOEMEMOS_ASC_ISSUER_ID].freeze
UDID_FORMAT = /\A(?:[0-9A-F]{40}|[0-9A-F]{8}-[0-9A-F]{16})\z/i

def apple_credentials
  credentials = APPLE_KEY_VARS.map { |name| ENV[name].to_s }
  return credentials unless credentials.all?(&:empty?)

  path = File.join(Dir.home, "Library", "Application Support", "Jarvis-iOS", "app-store-connect.json")
  return credentials unless File.exist?(path)

  config = JSON.parse(File.read(path))
  %w[key_path key_id issuer_id].map { |name| config.fetch(name) }
rescue SystemCallError, JSON::ParserError, KeyError
  abort "Cannot read App Store Connect credentials from #{path}."
end

def read_devices(path)
  devices = {}
  File.foreach(path, encoding: "bom|utf-8").with_index(1) do |line, number|
    next if number == 1 && line.start_with?("Device ID\t")
    next if line.strip.empty?

    udid, name, platform, extra = line.chomp.split("\t", -1).map(&:strip)
    legacy_row = name && !name.empty? && platform == "ios" && !extra
    unless UDID_FORMAT.match?(udid.to_s) && (name.nil? || legacy_row)
      abort "Invalid line #{number} in #{File.basename(path)}. Enter one UDID per line."
    end
    udid = udid.upcase
    devices[udid] ||= name || "iPhone #{udid[-8, 8]}"
  end
  abort "Add at least one iPhone to #{File.basename(path)}." if devices.empty?
  devices
rescue Errno::ENOENT, Errno::EACCES
  abort "Cannot read #{path}. Create the local device list before packaging."
end

def base64url(value)
  Base64.urlsafe_encode64(value, padding: false)
end

def apple_token(key_path, key_id, issuer_id)
  key = OpenSSL::PKey.read(File.binread(key_path))
  abort "The App Store Connect key must be a P-256 private key." unless key.is_a?(OpenSSL::PKey::EC) && key.private? && key.group.degree == 256

  now = Time.now.to_i
  header = {alg: "ES256", kid: key_id, typ: "JWT"}
  claims = {iss: issuer_id, iat: now, exp: now + 600, aud: "appstoreconnect-v1"}
  message = [header, claims].map { |part| base64url(JSON.generate(part)) }.join(".")
  der = key.dsa_sign_asn1(OpenSSL::Digest::SHA256.digest(message))
  signature = OpenSSL::ASN1.decode(der).value.map { |part| part.value.to_s(2).rjust(32, "\0") }.join
  "#{message}.#{base64url(signature)}"
rescue SystemCallError, OpenSSL::OpenSSLError
  abort "Cannot read the configured App Store Connect private key."
end

def apple_request(method, path, token, body = nil)
  url = URI("#{APPLE_API}#{path}")
  request = method.new(url)
  request["Authorization"] = "Bearer #{token}"
  if body
    request["Content-Type"] = "application/json"
    request.body = JSON.generate(body)
  end
  Net::HTTP.start(url.host, url.port, use_ssl: true, open_timeout: 15, read_timeout: 30) do |http|
    http.request(request)
  end
rescue SystemCallError, SocketError, Timeout::Error, OpenSSL::SSL::SSLError
  abort "Cannot reach the App Store Connect device API."
end

def find_device(udid, token)
  query = URI.encode_www_form("filter[udid]" => udid, "fields[devices]" => "udid,status")
  response = apple_request(Net::HTTP::Get, "/v1/devices?#{query}", token)
  abort "Could not check Apple device registration (HTTP #{response.code})." unless response.code == "200"

  JSON.parse(response.body).fetch("data").find do |item|
    item.fetch("attributes").fetch("udid").upcase == udid
  end
end

def register_devices(devices, token)
  registered = 0
  ids = devices.map do |udid, name|
    device = find_device(udid, token)
    status = device && device.fetch("attributes").fetch("status")
    next device.fetch("id") if status == "ENABLED"
    abort "A device in the list is #{status} in Apple Developer. Enable it before packaging." if status

    attributes = {udid: udid, name: name, platform: "IOS"}
    response = apple_request(Net::HTTP::Post, "/v1/devices", token, {data: {type: "devices", attributes: attributes}})
    if response.code == "201"
      registered += 1
      next JSON.parse(response.body).fetch("data").fetch("id")
    end
    if response.code == "409"
      device = find_device(udid, token)
      next device.fetch("id") if device && device.fetch("attributes").fetch("status") == "ENABLED"
    end

    abort "Apple declined to register a device (HTTP #{response.code}). Check the UDID, account permissions and device quota."
  end
  warn "Apple Developer: #{ids.length} device(s) enabled, #{registered} newly registered."
  ids
rescue JSON::ParserError, KeyError
  abort "App Store Connect returned an unexpected device response."
end

def apple_data(method, path, token, action, body = nil)
  response = apple_request(method, path, token, body)
  json = JSON.parse(response.body)
  unless response.is_a?(Net::HTTPSuccess)
    codes = json.fetch("errors", []).map { |item| item["code"] }.uniq.join(", ")
    abort "Could not #{action} (Apple HTTP #{response.code}: #{codes})."
  end
  json
end

def find_profile(bundle_id, name_prefix, token)
  path = "/v1/bundleIds/#{bundle_id}/profiles?limit=200"
  while path
    page = apple_data(Net::HTTP::Get, path, token, "list provisioning profiles")
    profile = page.fetch("data").map { |item| item.fetch("attributes") }.find do |attributes|
      attributes.fetch("name").start_with?(name_prefix) &&
        attributes.fetch("profileType") == "IOS_APP_ADHOC" &&
        attributes.fetch("profileState") == "ACTIVE" &&
        Time.iso8601(attributes.fetch("expirationDate")) > Time.now + 86400
    end
    return profile if profile

    next_link = page.fetch("links", {})["next"]
    path = next_link && URI(next_link).request_uri
  end
  nil
end

def ad_hoc_profile(identifier, certificate_id, device_ids, token)
  query = URI.encode_www_form("filter[identifier]" => identifier)
  bundles = apple_data(Net::HTTP::Get, "/v1/bundleIds?#{query}", token, "find the app bundle ID")
  bundle = bundles.fetch("data").find { |item| item.fetch("attributes").fetch("identifier") == identifier }
  abort "Register #{identifier} in Apple Developer before packaging." unless bundle
  bundle_id = bundle.fetch("id")
  fingerprint = OpenSSL::Digest::SHA256.hexdigest([certificate_id, *device_ids.sort].join("\n"))[0, 16]
  name_prefix = "Moe Memos #{identifier} Ad Hoc #{fingerprint} "
  profile = find_profile(bundle_id, name_prefix, token)
  if profile
    warn "Reusing the Ad Hoc provisioning profile."
    return Base64.strict_decode64(profile.fetch("profileContent"))
  end

  request = {
    data: {
      type: "profiles",
      attributes: {name: "#{name_prefix}#{Time.now.utc.strftime('%Y%m%d%H%M%S')}", profileType: "IOS_APP_ADHOC"},
      relationships: {
        bundleId: {data: {type: "bundleIds", id: bundle_id}},
        certificates: {data: [{type: "certificates", id: certificate_id}]},
        devices: {data: device_ids.map { |id| {type: "devices", id: id} }}
      }
    }
  }
  result = apple_data(Net::HTTP::Post, "/v1/profiles", token, "create the Ad Hoc provisioning profile", request)
  warn "Created the Ad Hoc provisioning profile."
  Base64.strict_decode64(result.fetch("data").fetch("attributes").fetch("profileContent"))
rescue JSON::ParserError, KeyError, ArgumentError
  abort "App Store Connect returned an unexpected provisioning profile response."
end

def ensure_bundle(identifier, name, token)
  query = URI.encode_www_form("filter[identifier]" => identifier)
  result = apple_data(Net::HTTP::Get, "/v1/bundleIds?#{query}", token, "find #{identifier}")
  bundle = result.fetch("data").find { |item| item.fetch("attributes").fetch("identifier") == identifier }
  unless bundle
    result = apple_data(Net::HTTP::Post, "/v1/bundleIds", token, "register #{identifier}", {
      data: {type: "bundleIds", attributes: {identifier: identifier, name: name, platform: "IOS"}}
    })
    bundle = result.fetch("data")
  end
  id = bundle.fetch("id")
  capabilities = apple_data(Net::HTTP::Get, "/v1/bundleIds/#{id}/bundleIdCapabilities", token, "read app capabilities")
  enabled = capabilities.fetch("data").map { |item| item.fetch("attributes").fetch("capabilityType") }
  desired = ["APP_GROUPS"]
  (desired - enabled).each do |capability|
    apple_data(Net::HTTP::Post, "/v1/bundleIdCapabilities", token, "enable #{capability} for #{identifier}", {
      data: {type: "bundleIdCapabilities", attributes: {capabilityType: capability},
             relationships: {bundleId: {data: {type: "bundleIds", id: id}}}}
    })
  end
  {identifier: identifier, id: id}
end

mode, certificate, directory, device_file, prefix = ARGV
unless ARGV.length == 5 && %w[--identifiers --profiles].include?(mode) &&
       certificate.match?(/\A[A-Z0-9]+\z/) && prefix.match?(/\A[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+\z/)
  abort "Usage: #{$PROGRAM_NAME} --identifiers|--profiles CERTIFICATE_ID DIRECTORY DEVICE_FILE BUNDLE_PREFIX"
end
devices = read_devices(device_file)
credentials = apple_credentials
abort "Configure all of #{APPLE_KEY_VARS.join(', ')}." if credentials.any?(&:empty?)
token = apple_token(*credentials)
device_ids = register_devices(devices, token)
File.write(File.join(directory, "requested-udids.txt"), devices.keys.join("\n") + "\n")
bundles = [
  [prefix, "Moe Memos Personal"],
  ["#{prefix}.share", "Moe Memos Personal Share"],
  ["#{prefix}.widgets", "Moe Memos Personal Widgets"]
]
registered = bundles.map { |identifier, name| ensure_bundle(identifier, name, token) }
if mode == "--identifiers"
  puts JSON.pretty_generate(registered)
  exit
end
registered.each do |bundle|
  profile = ad_hoc_profile(bundle.fetch(:identifier), certificate, device_ids, token)
  File.binwrite(File.join(directory, "#{bundle.fetch(:identifier)}.mobileprovision"), profile)
end
warn "Prepared #{registered.length} Ad Hoc profiles for #{devices.length} registered devices."
