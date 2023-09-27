# frozen_string_literal: true

source "https://rubygems.org"

gem "benchmark-ips"
gem "rake"
gem "rubocop"
gem "test-unit"

if File.directory?("../../ruby/prism")
  gem "prism", path: "../../ruby/prism"
else
  gem "prism"
end

gemspec
