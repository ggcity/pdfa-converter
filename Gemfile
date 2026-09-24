source "https://rubygems.org"

gem "sinatra"
gem "rackup"
gem "rubyzip"
# Must match the base64 default gem of the production Ruby: Passenger activates
# it before Bundler loads, so any other version fails to boot (Gem::LoadError).
gem "base64", "0.1.0"

group :development do
  gem "puma"
end