# frozen_string_literal: true

require "bundler/setup"
require "test/unit"

$:.unshift(File.expand_path("../lib", __dir__))
require "parser/yarp"
require "parser/current"

# First, opt in to every AST feature.
Parser::Builders::Default.modernize

# Modify the source map == check so that it doesn't check against the node
# itself so we don't get into a recursive loop.
Parser::Source::Map.prepend(
  Module.new {
    def ==(other)
      self.class == other.class &&
        (instance_variables - %i[@node]).map do |ivar|
          instance_variable_get(ivar) == other.instance_variable_get(ivar)
        end.reduce(:&)
    end
  }
)

# Next, ensure that we're comparing the nodes and also comparing the source
# ranges so that we're getting all of the necessary information.
Parser::AST::Node.prepend(
  Module.new {
    def ==(other)
      super && (location == other.location)
    end
  }
)

class YARPTest < Test::Unit::TestCase
  known_failures = %w[
    ambiuous_quoted_label_in_ternary_operator.rb
    and_asgn.rb
    args.rb
    args_args_assocs.rb
    args_args_assocs_comma.rb
    args_args_comma.rb
    args_assocs.rb
    args_assocs_comma.rb
    args_assocs_legacy.rb
    blockargs.rb
    bug_435.rb
    bug_cmdarg.rb
    bug_do_block_in_hash_brace.rb
    bug_heredoc_do.rb
    bug_lambda_leakage.rb
    bug_rescue_empty_else.rb
    bug_while_not_parens_do.rb
    case_cond.rb
    case_cond_else.rb
    case_expr.rb
    case_expr_else.rb
    class_definition_in_while_cond.rb
    cond_begin.rb
    cond_begin_masgn.rb
    cond_eflipflop.rb
    cond_iflipflop.rb
    cond_match_current_line.rb
    control_meta_escape_chars_in_regexp__since_31.rb
    dedenting_heredoc.rb
    dedenting_interpolating_heredoc_fake_line_continuation.rb
    dedenting_non_interpolating_heredoc_line_continuation.rb
    empty_stmt.rb
    endless_method_command_syntax.rb
    endless_method_forwarded_args_legacy.rb
    ensure.rb
    ensure_empty.rb
    for.rb
    for_mlhs.rb
    forward_arg.rb
    forward_arg_with_open_args.rb
    forward_args_legacy.rb
    forwarded_kwrestarg_with_additional_kwarg.rb
    hash_hashrocket.rb
    hash_kwsplat.rb
    hash_label.rb
    hash_label_end.rb
    hash_pair_value_omission.rb
    heredoc.rb
    if.rb
    if_else.rb
    if_elsif.rb
    if_masgn__24.rb
    if_nl_then.rb
    if_while_after_class__since_32.rb
    interp_digit_var.rb
    keyword_argument_omission.rb
    kwnilarg.rb
    lvar_injecting_match.rb
    masgn.rb
    masgn_attr.rb
    masgn_const.rb
    masgn_nested.rb
    method_definition_in_while_cond.rb
    multiple_pattern_matches.rb
    newline_in_hash_argument.rb
    not.rb
    numbered_args_after_27.rb
    op_asgn_cmd.rb
    op_asgn_index.rb
    op_asgn_index_cmd.rb
    or_asgn.rb
    parser_bug_272.rb
    parser_bug_507.rb
    parser_bug_525.rb
    parser_bug_640.rb
    parser_bug_645.rb
    parser_drops_truncated_parts_of_squiggly_heredoc.rb
    parser_slash_slash_n_escaping_in_literals.rb
    pattern_match.rb
    pattern_matching_blank_else.rb
    pattern_matching_else.rb
    pattern_matching_single_line_allowed_omission_of_parentheses.rb
    procarg0.rb
    range_endless.rb
    regex_plain.rb
    resbody_list.rb
    resbody_list_mrhs.rb
    resbody_list_var.rb
    resbody_var.rb
    rescue.rb
    rescue_else.rb
    rescue_else_ensure.rb
    rescue_ensure.rb
    rescue_in_lambda_block.rb
    rescue_without_begin_end.rb
    ruby_bug_10279.rb
    ruby_bug_10653.rb
    ruby_bug_11107.rb
    ruby_bug_11380.rb
    ruby_bug_11873.rb
    ruby_bug_11989.rb
    ruby_bug_11990.rb
    ruby_bug_12073.rb
    ruby_bug_12402.rb
    ruby_bug_13547.rb
    ruby_bug_15789.rb
    ruby_bug_9669.rb
    send_attr_asgn.rb
    send_attr_asgn_conditional.rb
    send_call.rb
    send_index.rb
    send_index_asgn.rb
    send_index_asgn_legacy.rb
    send_index_cmd.rb
    send_index_legacy.rb
    send_lambda.rb
    send_lambda_args.rb
    send_lambda_args_noparen.rb
    send_lambda_args_shadow.rb
    send_lambda_legacy.rb
    slash_newline_in_heredocs.rb
    ternary.rb
    ternary_ambiguous_symbol.rb
    unary_num_pow_precedence.rb
    unless.rb
    unless_else.rb
    until.rb
    when_multi.rb
    when_splat.rb
    when_then.rb
    while.rb
  ]

  Dir[File.expand_path("fixtures/*.rb", __dir__)].each do |filepath|
    next if known_failures.include?(File.basename(filepath))
    define_method("test_#{filepath}") { assert_parses(filepath) }
  end

  private

  def assert_parses(filepath)
    parser = Parser::CurrentRuby.default_parser
    parser.diagnostics.consumer = ->(*) {}
    parser.diagnostics.all_errors_are_fatal = true
  
    buffer = Parser::Source::Buffer.new(filepath, 1)
    buffer.source = File.read(filepath)
  
    expected = parser.parse(buffer)
    actual = Parser::YARP.parse(buffer)
    queue = [[expected, actual]]
  
    while (left, right = queue.shift)
      assert_equal(left.location, right.location)
  
      left.children.zip(right.children).each do |left_child, right_child|
        queue << [left_child, right_child] if left_child.is_a?(Parser::AST::Node)
      end
    end
  end
end
