#!/bin/sh

set -eu

export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"
export LC_CTYPE="en_US.UTF-8"
export RUBYOPT="${RUBYOPT:-} -EUTF-8:UTF-8"

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$SCRIPT_DIR/cocoapods-podx"
GEMSPEC_PATH="$PLUGIN_DIR/cocoapods-podx.gemspec"
NEXUS_GEM_SOURCE="${COCOAPODS_PODX_GEM_SOURCE:-${COCOAPODS_OVERLAY_GEM_SOURCE:-http://172.31.4.4:9091/repository/nn_ios/rubygems/cocoapods-podx/}}"
NEXUS_USER="${COCOAPODS_PODX_NEXUS_USER:-${COCOAPODS_OVERLAY_NEXUS_USER:-admin}}"
NEXUS_PASSWORD="${COCOAPODS_PODX_NEXUS_PASSWORD:-${COCOAPODS_OVERLAY_NEXUS_PASSWORD:-admin123}}"
REQUESTED_VERSION="${1:-${COCOAPODS_PODX_VERSION:-${COCOAPODS_OVERLAY_VERSION:-}}}"

detect_ruby_bin() {
  if [ -n "${COCOAPODS_PODX_RUBY_BIN:-}" ]; then
    printf '%s\n' "$COCOAPODS_PODX_RUBY_BIN"
    return 0
  fi

  pod_bin="$(command -v pod 2>/dev/null || true)"
  if [ -n "$pod_bin" ] && [ -f "$pod_bin" ]; then
    pod_shebang="$(sed -n '1s/^#!//p' "$pod_bin")"
    case "$pod_shebang" in
      */ruby)
        if [ -x "$pod_shebang" ]; then
          printf '%s\n' "$pod_shebang"
          return 0
        fi
        ;;
    esac
  fi

  command -v ruby
}

RUBY_BIN="$(detect_ruby_bin)"
GEM_BIN="${COCOAPODS_PODX_GEM_BIN:-$(dirname "$RUBY_BIN")/gem}"
if [ ! -x "$GEM_BIN" ]; then
  GEM_BIN="$(command -v gem)"
fi

if [ ! -f "$GEMSPEC_PATH" ]; then
  echo "Missing gemspec: $GEMSPEC_PATH" >&2
  exit 1
fi

CURRENT_VERSION="$("$RUBY_BIN" -e "spec = Gem::Specification.load(ARGV[0]); abort('Failed to load gemspec') unless spec; puts spec.version" "$GEMSPEC_PATH")"
LATEST_NEXUS_VERSION=""

if [ -z "$REQUESTED_VERSION" ]; then
  LATEST_NEXUS_VERSION="$("$RUBY_BIN" -rjson -rnet/http -ruri -e '
source = ARGV[0]
user = ARGV[1]
password = ARGV[2]

begin
  source_uri = URI(source)
  match = source_uri.path.match(%r{\A/repository/([^/]+)/(.*?)/?\z})
  raise "Invalid Nexus raw source: #{source}" unless match

  repository = match[1]
  asset_prefix = match[2].sub(%r{/+\z}, "")
  base = "#{source_uri.scheme}://#{source_uri.host}"
  base += ":#{source_uri.port}" if source_uri.port && ![80, 443].include?(source_uri.port)

  versions = []
  token = nil

  loop do
    query = "repository=#{URI.encode_www_form_component(repository)}"
    query += "&continuationToken=#{URI.encode_www_form_component(token)}" if token
    uri = URI("#{base}/service/rest/beta/search/assets?#{query}")
    request = Net::HTTP::Get.new(uri)
    request.basic_auth(user, password) unless user.empty? || password.empty?
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") { |http| http.request(request) }
    raise "Nexus search failed: HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

    body = JSON.parse(response.body)
    body.fetch("items", []).each do |item|
      path = item["path"].to_s
      next unless path.start_with?("#{asset_prefix}/")

      file = File.basename(path)
      match = file.match(/\Acocoapods-podx-(\d+(?:\.\d+)*)\.gem\z/)
      versions << match[1] if match
    end

    token = body["continuationToken"]
    break if token.nil? || token.to_s.empty?
  end

  puts versions.max_by { |version| version.split(".").map(&:to_i) }
rescue => e
  warn "warning: #{e.message}"
end
' "$NEXUS_GEM_SOURCE" "$NEXUS_USER" "$NEXUS_PASSWORD")"
fi

if [ -n "$REQUESTED_VERSION" ]; then
  VERSION="$REQUESTED_VERSION"
else
  BASE_VERSION="${LATEST_NEXUS_VERSION:-$CURRENT_VERSION}"
  VERSION="$("$RUBY_BIN" -e '
version = ARGV[0].split(".")
abort("Invalid version: #{ARGV[0]}") if version.empty? || version.any? { |part| part !~ /\A\d+\z/ }
version[-1] = (version[-1].to_i + 1).to_s
puts version.join(".")
' "$BASE_VERSION")"
fi

"$RUBY_BIN" -e '
path = ARGV[0]
version = ARGV[1]
abort("Invalid version: #{version}") unless version.match?(/\A\d+(?:\.\d+)*\z/)
content = File.read(path)
version_pattern = /spec\.version\s*=\s*["'\'']([^"'\'']+)["'\'']/
match = content.match(version_pattern)
abort("Unable to find version in #{path}") unless match
if match[1] == version
  exit
end
updated = content.sub(version_pattern, "spec.version       = #{version.inspect}")
File.write(path, updated)
' "$GEMSPEC_PATH" "$VERSION"

if [ -n "$REQUESTED_VERSION" ]; then
  echo "Preparing cocoapods-podx $VERSION (specified version, local previous: $CURRENT_VERSION) ..."
else
  echo "Preparing cocoapods-podx $VERSION (Nexus latest: ${LATEST_NEXUS_VERSION:-none}, local previous: $CURRENT_VERSION) ..."
fi

cd "$PLUGIN_DIR"
"$GEM_BIN" build cocoapods-podx.gemspec
find "$PLUGIN_DIR" -maxdepth 1 -name 'cocoapods-podx-*.gem' ! -name "cocoapods-podx-$VERSION.gem" -delete

GEM_FILE="$PLUGIN_DIR/cocoapods-podx-$VERSION.gem"
if [ ! -f "$GEM_FILE" ]; then
  echo "Missing gem file after build: $GEM_FILE" >&2
  exit 1
fi

TARGET_URL="${NEXUS_GEM_SOURCE%/}/cocoapods-podx-$VERSION.gem"

echo "Publishing cocoapods-podx $VERSION to $TARGET_URL ..."
if [ -n "$NEXUS_USER" ] && [ -n "$NEXUS_PASSWORD" ]; then
  curl -fL -u "$NEXUS_USER:$NEXUS_PASSWORD" --upload-file "$GEM_FILE" "$TARGET_URL"
else
  curl -fL --upload-file "$GEM_FILE" "$TARGET_URL"
fi

echo "Published cocoapods-podx $VERSION"
echo "Verify with:"
echo "  curl -I \"$TARGET_URL\""
echo "  curl -L -o /tmp/cocoapods-podx-$VERSION.gem \"$TARGET_URL\""
echo "  gem install --local /tmp/cocoapods-podx-$VERSION.gem --ignore-dependencies --no-document"
