# parser-yarp

This is an early experiment in building the [whitequark/parser](https://github.com/whitequark/parser) gem's syntax tree using the [YARP](https://github.com/ruby/yarp) parser.

## Installation

Add this line to your application's Gemfile:

```ruby
gem "parser-yarp"
```

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install parser-yarp

## Usage

The `parser` gem provides multiple parsers to support different versions of the Ruby grammar. This includes all of the Ruby versions going back to 1.8, as well as third-party parsers like MacRuby and RubyMotion. The `parser-yarp` gem provides another parser that uses the `YARP` parser to build the syntax tree.

You can use the `YARP` parser like you would any other. After requiring the parser, you should be able to call any of the regular `Parser::Base` APIs that you would normally use.

```ruby
require "parser/yarp"

Parser::YARP.parse_file("path/to/file.rb")
```

### RuboCop

To run RuboCop using the `parser-yarp` gem as the parser, you will need to require the `parser/yarp/rubocop` file. This file injects `YARP` into the known options for both `rubocop` and `rubocop-ast`, such that you can specify it in your `.rubocop.yml` file. Unfortunately `rubocop` doesn't support any direct way to do this, so we have to get a bit hacky.

First, set the `TargetRubyVersion` in your RuboCop configuration file to `89_65_82_80.33`. This is the version of Ruby that `YARP` reports itself as. (The leading numbers are the ASCII values for `YARP`.)

```yaml
AllCops:
  TargetRubyVersion: 89_65_82_80.33
```

Now when you run `rubocop` you will need to require the `parser/yarp/rubocop` file before executing so that it can inject the `YARP` parser into the known options.

```
bundle exec ruby -rparser/yarp/rubocop $(bundle exec which rubocop)
```

This should run RuboCop using the `YARP` parser.

## Benchmarks

As a whole, this parser should be significantly faster than the `parser` gem. The `bin/bench` script in this repository compares the performance of `Parser::CurrentRuby` and `Parser::YARP`. Running against a large file like `lib/parser/yarp/compiler.rb` yields:

```
Warming up --------------------------------------
 Parser::CurrentRuby     1.000  i/100ms
        Parser::YARP     6.000  i/100ms
Calculating -------------------------------------
 Parser::CurrentRuby     17.184  (± 0.0%) i/s -     86.000  in   5.006166s
        Parser::YARP     68.121  (± 2.9%) i/s -    342.000  in   5.023905s

Comparison:
        Parser::YARP:       68.1 i/s
 Parser::CurrentRuby:       17.2 i/s - 3.96x  slower
```

When running with `--yjit`, the comparison is even more stark:

```
Warming up --------------------------------------
 Parser::CurrentRuby     1.000  i/100ms
        Parser::YARP     9.000  i/100ms
Calculating -------------------------------------
 Parser::CurrentRuby     19.570  (± 5.1%) i/s -     98.000  in   5.016435s
        Parser::YARP    109.392  (± 4.6%) i/s -    549.000  in   5.032282s

Comparison:
        Parser::YARP:      109.4 i/s
 Parser::CurrentRuby:       19.6 i/s - 5.59x  slower
```

These benchmarks were run on a single laptop without a lot of control for other processes, so take them with a grain of salt.

## Development

Run `rake test` to run the tests. This runs tests exported from the `parser` gem into their own fixture files.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/kddnewton/parser-yarp.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
