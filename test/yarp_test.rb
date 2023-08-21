# frozen_string_literal: true

require "bundler/setup"
require "test/unit"

$:.unshift(File.expand_path("../lib", __dir__))
require "parser/yarp"

class YARPTest < Test::Unit::TestCase
  skip = [
    # These files contain invalid syntax. We should never try to parse them.
    "control_meta_escape_chars_in_regexp__since_31.rb",
    "pattern_match.rb",
    "range_endless.rb",
    "unary_num_pow_precedence.rb",

    # This is some kind of difference between when we combine dstr into str
    # sexps on escaped newlines.
    "parser_slash_slash_n_escaping_in_literals.rb",
    "ruby_bug_11989.rb",

    # We don't yet support numbered parameters. This is a bug in YARP.
    "numbered_args_after_27.rb",
    "ruby_bug_15789.rb",

    # We have an issue here with rescue modifier precedence. This is a bug in
    # YARP.
    "endless_method_command_syntax.rb",
    "ruby_bug_12402.rb",

    # These are location bounds issues. They are bugs in translation, but not
    # bugs in YARP.
    "bug_rescue_empty_else.rb",
    "ensure_empty.rb",
    "rescue_else.rb",
    "rescue_else_ensure.rb",
    "rescue_in_lambda_block.rb",

    # Some kind of issue with the end location of heredocs including newlines.
    "dedenting_heredoc.rb"
  ]

  base = File.expand_path("fixtures", __dir__)
  Dir["*.rb", base: base].each do |filename|
    next if skip.include?(filename)

    filepath = File.join(base, filename)
    define_method("test_#{filepath}") { assert(Parser::YARP.compare(filepath)) }
  end
end
