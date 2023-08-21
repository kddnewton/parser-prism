# frozen_string_literal: true

require "parser/current"
require "yarp"

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

module Parser
  module YARP
    class Visitor < ::YARP::BasicVisitor
      attr_reader :buffer, :context

      def initialize(buffer)
        @buffer = buffer
        @context = { destructure: false, locals: [], pattern: false }
      end

      # alias foo bar
      # ^^^^^^^^^^^^^
      def visit_alias_node(node)
        s(:alias,  [visit(node.new_name), visit(node.old_name)], smap_keyword_bare(srange(node.keyword_loc), srange(node.location)))
      end

      # foo => bar | baz
      #        ^^^^^^^^^
      def visit_alternation_pattern_node(node)
        s(:match_alt, [visit(node.left), visit(node.right)], smap_operator(srange(node.operator_loc), srange(node.location)))
      end

      # a and b
      # ^^^^^^^
      def visit_and_node(node)
        s(:and, [visit(node.left), visit(node.right)], smap_operator(srange(node.operator_loc), srange(node.location)))
      end

      # a &&= b
      # ^^^^^^^
      def visit_and_write_node(node)
        s(:and_asgn, [visit(node.target), visit(node.value)], smap_variable(srange(node.target.location), srange(node.location)).with_operator(srange(node.operator_loc)))
      end

      # []
      # ^^
      def visit_array_node(node)
        children =
          node.elements.map do |element|
            case element
            when ::YARP::KeywordHashNode
              visited = visit(element)
              s(:hash, visited.children, visited.location)
            else
              visit(element)
            end
          end

        s(:array, children, smap_collection(srange(node.opening_loc), srange(node.closing_loc), srange(node.location)))
      end

      # foo => [bar]
      #        ^^^^^
      def visit_array_pattern_node(node)
        s(:array_pattern, visit_all(node.requireds), smap_collection(srange(node.opening_loc), srange(node.closing_loc), srange(node.location)))
      end

      # foo(bar)
      #     ^^^
      def visit_arguments_node(node)
        case node.arguments.length
        when 0
          raise
        when 1
          [visit(node.arguments.first)]
        else
          visit_all(node.arguments)
        end
      end

      # { a: 1 }
      #   ^^^^
      def visit_assoc_node(node)
        if context[:pattern] && node.value.nil?
          s(:match_var, [node.key.unescaped.to_sym], smap_variable(srange(node.key.value_loc), srange(node.key.location)))
        elsif node.value.nil?
          key_name = node.key.unescaped.to_sym
          key_location = srange_offsets(node.key.location.start_offset, node.key.location.end_offset - 1)

          key_value =
            if key_name[0].match?(/[[:upper:]]/)
              s(:const, [nil, key_name], smap_constant(nil, key_location, key_location))
            else
              s(:send, [nil, key_name], smap_send_bare(key_location, key_location))
            end

          s(:pair, [s(:sym, [key_name], smap_collection_bare(key_location)), key_value], smap_operator(srange(node.key.closing_loc), srange(node.location)))
        elsif node.key.is_a?(::YARP::SymbolNode) && node.key.closing&.end_with?(":")
          visited = visit(node.key)
          s(:pair, [s(visited.type, visited.children, smap_collection(srange(node.key.opening_loc), node.key.closing_loc.start_offset == node.key.closing_loc.end_offset - 1 ? nil : srange_offsets(node.key.closing_loc.start_offset, node.key.closing_loc.end_offset - 1), srange_offsets(node.key.location.start_offset, node.key.location.end_offset - 1))), visit(node.value)], smap_operator(srange_offsets(node.key.closing_loc.end_offset - 1, node.key.closing_loc.end_offset), srange(node.location)))
        else
          s(:pair, [visit(node.key), visit(node.value)], smap_operator(srange(node.operator_loc), srange(node.location)))
        end
      end

      # def foo(**); bar(**); end
      #                  ^^
      #
      # { **foo }
      #   ^^^^^
      def visit_assoc_splat_node(node)
        if node.value.nil? && context[:locals].include?(:**)
          s(:forwarded_kwrestarg, [], smap(srange(node.location)))
        else
          s(:kwsplat, [visit(node.value)], smap_operator(srange(node.operator_loc), srange(node.location)))
        end
      end

      # $+
      # ^^
      def visit_back_reference_read_node(node)
        s(:back_ref, [node.slice.to_sym], smap(srange(node.location)))
      end

      # begin end
      # ^^^^^^^^^
      def visit_begin_node(node)
        if node.rescue_clause.nil? && node.ensure_clause.nil? && node.else_clause.nil?
          children =
            if node.statements.nil?
              []
            else
              child = visit(node.statements)
              child.type == :begin ? child.children : [child]
            end

          s(:kwbegin, children, smap_collection(srange(node.begin_keyword_loc), srange(node.end_keyword_loc), srange(node.location)))
        else
          result = visit(node.statements)

          if node.rescue_clause
            rescue_node = visit(node.rescue_clause)

            children = [result] + rescue_node.children
            if node.else_clause
              children.pop
              children << visit(node.else_clause)
            end

            rescue_location = rescue_node.location
            if node.statements
              rescue_location = rescue_location.with_expression(srange_offsets(node.statements.location.start_offset, node.rescue_clause.location.end_offset))
            end

            result = s(rescue_node.type, children, rescue_location)
          end

          if node.ensure_clause
            ensure_node = visit(node.ensure_clause)

            ensure_location = ensure_node.location
            if node.statements
              ensure_location = ensure_location.with_expression(srange_offsets(node.statements.location.start_offset, (node.ensure_clause.statements&.location || node.ensure_clause.keyword_loc).end_offset))
            end

            result = s(ensure_node.type, [result] + ensure_node.children, ensure_location)
          end

          if node.begin_keyword_loc
            s(:kwbegin, [result], smap_collection(srange(node.begin_keyword_loc), srange(node.end_keyword_loc), srange(node.location)))
          else
            result
          end
        end
      end

      # foo(&bar)
      #     ^^^^
      def visit_block_argument_node(node)
        s(:block_pass, [visit(node.expression)], smap_operator(srange(node.operator_loc), srange(node.location)))
      end

      # A block on a keyword or method call.
      def visit_block_node(node)
        if node.parameters.nil?
          [s(:args, [], smap_collection_bare(nil)), visit(node.body)]
        elsif (parameter = procarg0(node.parameters))
          [parameter, visit(node.body)]
        else
          [s(:args, visit(node.parameters), smap_collection(srange(node.parameters.opening_loc), srange(node.parameters.closing_loc), srange(node.parameters.location))), visit(node.body)]
        end
      end

      # def foo(&bar); end
      #         ^^^^
      def visit_block_parameter_node(node)
        s(:blockarg, [node.name&.to_sym], smap_variable(srange(node.name_loc), srange(node.location)))
      end

      # A block's parameters.
      def visit_block_parameters_node(node)
        [*visit(node.parameters)].concat(node.locals.map { |local| s(:shadowarg, [local.slice.to_sym], smap_variable(srange(local), srange(local))) })
      end

      # break
      # ^^^^^
      #
      # break foo
      # ^^^^^^^^^
      def visit_break_node(node)
        s(:break, visit(node.arguments), smap_keyword_bare(srange(node.keyword_loc), srange(node.location)))
      end

      # foo
      # ^^^
      #
      # foo.bar
      # ^^^^^^^
      #
      # foo.bar() {}
      # ^^^^^^^^^^^^
      def visit_call_node(node)
        if node.message == "=~" && node.receiver.is_a?(::YARP::RegularExpressionNode) && node.arguments && node.arguments.arguments.length == 1
          return s(:match_with_lvasgn, [visit(node.receiver), visit(node.arguments.arguments.first)], smap_send_bare(srange(node.message_loc), srange(node.location)))
        elsif node.message == "not" && !node.receiver && node.opening_loc && node.closing_loc && !node.arguments
          return s(:send, [s(:begin, [], smap_collection(srange(node.opening_loc), srange(node.closing_loc), srange(node.opening_loc.to(node.closing_loc)))), :!], smap_send_bare(srange(node.message_loc), srange(node.location)))
        end

        type = node.safe_navigation? ? :csend : :send
        parts = [visit(node.receiver), node.name.to_sym]
        parts.concat(visit(node.arguments)) unless node.arguments.nil?

        call_expression =
          if node.block
            srange_offsets(node.location.start_offset, (node.closing_loc || node.arguments&.location || node.message_loc).end_offset)
          else
            srange(node.location)
          end

        call =
          if node.name == "[]"
            parts.delete_at(1)
            s(:index, parts, smap_index(srange_offsets(node.message_loc.start_offset, node.message_loc.start_offset + 1), srange_offsets(node.message_loc.end_offset - 1, node.message_loc.end_offset), call_expression))
          elsif node.name == "[]=" && node.message != "[]="
            parts.delete_at(1)
            s(:indexasgn, parts, smap_index(srange_offsets(node.message_loc.start_offset, node.message_loc.start_offset + 1), srange_offsets(node.message_loc.end_offset - 1, node.message_loc.end_offset), call_expression).with_operator(srange_find(node.message_loc.end_offset, node.arguments.arguments.last.location.start_offset, ["="])))
          elsif node.name.end_with?("=") && !node.message.end_with?("=") && node.arguments
            s(type, parts, smap_send(srange(node.operator_loc), srange(node.message_loc), srange(node.opening_loc), srange(node.closing_loc), call_expression).with_operator(srange_find(node.message_loc.end_offset, node.arguments.arguments.last.location.start_offset, ["="])))
          else
            s(type, parts, smap_send(srange(node.operator_loc), srange(node.message_loc), srange(node.opening_loc), srange(node.closing_loc), call_expression))
          end

        node.block ? s(:block, [call].concat(visit(node.block)), smap_collection(srange(node.block.opening_loc), srange(node.block.closing_loc), srange(node.location))) : call
      end

      # foo.bar &&= baz
      # ^^^^^^^^^^^^^^^
      #
      # foo[bar] &&= baz
      # ^^^^^^^^^^^^^^^^
      def visit_call_operator_and_write_node(node)
        location =
          if node.target.name == "[]=" && node.target.message != "[]="
            smap_index(srange_offsets(node.target.message_loc.start_offset, node.target.message_loc.start_offset + 1), srange_offsets(node.target.message_loc.end_offset - 1, node.target.message_loc.end_offset), srange(node.location)).with_operator(srange(node.operator_loc))
          else
            smap_send(srange(node.target.operator_loc), srange(node.target.message_loc), nil, nil, srange(node.location)).with_operator(srange(node.operator_loc))
          end

        s(:and_asgn, [visit_call_operator_write(node.target), visit(node.value)], location)
      end

      # foo.bar ||= baz
      # ^^^^^^^^^^^^^^^
      #
      # foo[bar] ||= baz
      # ^^^^^^^^^^^^^^^^
      def visit_call_operator_or_write_node(node)
        location =
          if node.target.name == "[]=" && node.target.message != "[]="
            smap_index(srange_offsets(node.target.message_loc.start_offset, node.target.message_loc.start_offset + 1), srange_offsets(node.target.message_loc.end_offset - 1, node.target.message_loc.end_offset), srange(node.location)).with_operator(srange(node.operator_loc))
          else
            smap_send(srange(node.target.operator_loc), srange(node.target.message_loc), nil, nil, srange(node.location)).with_operator(srange(node.operator_loc))
          end

        s(:or_asgn, [visit_call_operator_write(node.target), visit(node.value)], location)
      end

      # foo.bar += baz
      # ^^^^^^^^^^^^^^^
      #
      # foo[bar] += baz
      # ^^^^^^^^^^^^^^^
      def visit_call_operator_write_node(node)
        location =
          if node.target.name == "[]=" && node.target.message != "[]="
            smap_index(srange_offsets(node.target.message_loc.start_offset, node.target.message_loc.start_offset + 1), srange_offsets(node.target.message_loc.end_offset - 1, node.target.message_loc.end_offset), srange(node.location)).with_operator(srange(node.operator_loc))
          else
            smap_send(srange(node.target.operator_loc), srange(node.target.message_loc), nil, nil, srange(node.location)).with_operator(srange(node.operator_loc))
          end

        s(:op_asgn, [visit_call_operator_write(node.target), node.operator.chomp("=").to_sym, visit(node.value)], location)
      end

      # foo => bar => baz
      #        ^^^^^^^^^^
      def visit_capture_pattern_node(node)
        s(:match_as, [visit(node.value), visit(node.target)], smap_operator(srange(node.operator_loc), srange(node.location)))
      end

      # case foo; when bar; end
      # ^^^^^^^^^^^^^^^^^^^^^^^
      #
      # case foo; in bar; end
      # ^^^^^^^^^^^^^^^^^^^^^
      def visit_case_node(node)
        if node.conditions.first.is_a?(::YARP::WhenNode)
          s(:case, [visit(node.predicate), *visit_all(node.conditions), visit(node.consequent)], smap_condition(srange(node.case_keyword_loc), nil, srange(node.consequent&.else_keyword_loc), srange(node.end_keyword_loc), srange(node.location)))
        else
          s(:case_match, [visit(node.predicate), *visit_all(node.conditions), node.consequent && node.consequent.statements.nil? ? s(:empty_else, [], smap(srange(node.consequent.else_keyword_loc))) : visit(node.consequent)], smap_condition(srange(node.case_keyword_loc), nil, srange(node.consequent&.else_keyword_loc), srange(node.end_keyword_loc), srange(node.location)))
        end
      end

      # class Foo; end
      # ^^^^^^^^^^^^^^
      def visit_class_node(node)
        s(:class, [visit(node.constant_path), visit(node.superclass), with_context(:locals, node.locals) { visit(node.body) }], smap_definition(srange(node.class_keyword_loc), srange(node.inheritance_operator_loc), srange(node.constant_path.location), srange(node.end_keyword_loc)))
      end

      # @@foo
      # ^^^^^
      def visit_class_variable_read_node(node)
        s(:cvar, [node.slice.to_sym], smap_variable(srange(node.location), srange(node.location)))
      end

      # @@foo = 1
      # ^^^^^^^^^
      #
      # @@foo, @@bar = 1
      # ^^^^^  ^^^^^
      def visit_class_variable_write_node(node)
        if node.value
          s(:cvasgn, [node.name.to_sym, visit(node.value)], smap_variable(srange(node.name_loc), srange(node.location)).with_operator(srange(node.operator_loc)))
        else
          s(:cvasgn, [node.name.to_sym], smap_variable(srange(node.name_loc), srange(node.location)))
        end
      end

      # Foo::Bar
      # ^^^^^^^^
      def visit_constant_path_node(node)
        raise unless node.child.is_a?(::YARP::ConstantReadNode)
        s(:const, [node.parent ? visit(node.parent) : s(:cbase, [], smap(srange(node.delimiter_loc))), node.child.slice.to_sym], smap_constant(srange(node.delimiter_loc), srange(node.child.location), srange(node.location)))
      end

      # Foo::Bar = 1
      # ^^^^^^^^^^^^
      #
      # Foo::Foo, Bar::Bar = 1
      # ^^^^^^^^  ^^^^^^^^
      def visit_constant_path_write_node(node)
        if node.value
          s(:casgn, [*visit(node.target).children, visit(node.value)], smap_constant(srange(node.target.delimiter_loc), srange(node.target.child.location), srange(node.location)).with_operator(srange(node.operator_loc)))
        else
          s(:casgn, visit(node.target).children, smap_constant(srange(node.target.delimiter_loc), srange(node.target.child.location), srange(node.location)))
        end
      end

      # Foo
      # ^^^
      def visit_constant_read_node(node)
        s(:const, [nil, node.slice.to_sym], smap_constant(nil, srange(node.location), srange(node.location)))
      end

      # Foo = 1
      # ^^^^^^^
      #
      # Foo, Bar = 1
      # ^^^  ^^^
      def visit_constant_write_node(node)
        if node.value
          s(:casgn, [nil, node.name.to_sym, visit(node.value)], smap_constant(nil, srange(node.name_loc), srange(node.location)).with_operator(srange(node.operator_loc)))
        else
          s(:casgn, [nil, node.name.to_sym], smap_constant(nil, srange(node.name_loc), srange(node.location)))
        end
      end

      # def foo; end
      # ^^^^^^^^^^^^
      #
      # def self.foo; end
      # ^^^^^^^^^^^^^^^^^
      def visit_def_node(node)
        receiver =
          if node.receiver.is_a?(::YARP::ParenthesesNode)
            node.receiver.body
          else
            node.receiver
          end

        parts = [
          node.name.to_sym,
          if node.parameters.nil?
            if node.lparen_loc && node.rparen_loc
              s(:args, [], smap_collection(srange(node.lparen_loc), srange(node.rparen_loc), srange(node.lparen_loc.to(node.rparen_loc))))
            else
              s(:args, [], smap_collection_bare(nil))
            end
          else
            if node.lparen_loc && node.rparen_loc
              s(:args, visit(node.parameters), smap_collection(srange(node.lparen_loc), srange(node.rparen_loc), srange_offsets(node.lparen_loc.start_offset, node.rparen_loc.end_offset)))
            else
              s(:args, visit(node.parameters), smap_collection_bare(srange(node.parameters.location)))
            end
          end,
          with_context(:locals, node.locals) { visit(node.body) }
        ]

        location =
          smap_method_definition(
            srange(node.def_keyword_loc),
            srange(node.operator_loc),
            srange(node.name_loc),
            srange(node.end_keyword_loc),
            srange(node.equal_loc),
            srange(node.location)
          )

        if receiver
          s(:defs, [visit(receiver), *parts], location)
        else
          s(:def, parts, location)
        end
      end

      # defined? a
      # ^^^^^^^^^^
      #
      # defined?(a)
      # ^^^^^^^^^^^
      def visit_defined_node(node)
        s(:defined?, [visit(node.value)], smap_keyword(srange(node.keyword_loc), srange(node.lparen_loc), srange(node.rparen_loc), srange(node.location)))
      end

      # if foo then bar else baz end
      #                 ^^^^^^^^^^^^
      def visit_else_node(node)
        visit(node.statements)
      end

      # "foo #{bar}"
      #      ^^^^^^
      def visit_embedded_statements_node(node)
        s(:begin, node.statements ? [visit(node.statements)] : [], smap_collection(srange(node.opening_loc), srange(node.closing_loc), srange(node.location)))
      end

      # "foo #@bar"
      #      ^^^^^
      def visit_embedded_variable_node(node)
        visit(node.variable)
      end

      # begin; foo; ensure; bar; end
      #             ^^^^^^^^^^^^
      def visit_ensure_node(node)
        s(:ensure, [visit(node.statements)], smap_condition(srange(node.ensure_keyword_loc), nil, nil, nil, srange(node.location)))
      end

      # false
      # ^^^^^
      def visit_false_node(node)
        s(:false, [], smap(srange(node.location)))
      end

      # foo => [*, bar, *]
      #        ^^^^^^^^^^^
      def visit_find_pattern_node(node)
        s(:find_pattern, [s(:match_rest, [], smap_operator(srange(node.left.operator_loc), srange(node.left.location))), *visit_all(node.requireds), s(:match_rest, [], smap_operator(srange(node.right.operator_loc), srange(node.right.location)))], smap_collection(srange(node.opening_loc), srange(node.closing_loc), srange(node.location)))
      end

      # if foo .. bar; end
      #    ^^^^^^^^^^
      def visit_flip_flop_node(node)
        s(node.exclude_end? ? :eflipflop : :iflipflop, [visit(node.left), visit(node.right)], smap_operator(srange(node.operator_loc), srange(node.location)))
      end

      # 1.0
      # ^^^
      def visit_float_node(node)
        s(:float, [node.value], smap_operator(node.slice.match?(/^[+-]/) ? srange_offsets(node.location.start_offset, node.location.start_offset + 1) : nil, srange(node.location)))
      end

      # for foo in bar do end
      # ^^^^^^^^^^^^^^^^^^^^^
      def visit_for_node(node)
        s(:for, [visit(node.index), visit(node.collection), visit(node.statements)], smap_for(srange(node.for_keyword_loc), srange(node.in_keyword_loc), node.do_keyword_loc ? srange(node.do_keyword_loc) : srange_find(node.collection.location.end_offset, (node.statements&.location || node.end_keyword_loc).start_offset, [";"]), srange(node.end_keyword_loc), srange(node.location)))
      end

      # def foo(...); bar(...); end
      #                   ^^^
      def visit_forwarding_arguments_node(node)
        s(:forwarded_args, [], smap(srange(node.location)))
      end

      # def foo(...); end
      #         ^^^
      def visit_forwarding_parameter_node(node)
        s(:forward_arg, [], smap(srange(node.location)))
      end

      # super
      # ^^^^^
      #
      # super {}
      # ^^^^^^^^
      def visit_forwarding_super_node(node)
        if node.block
          s(:block, [s(:zsuper, [], smap_keyword_bare(srange_offsets(node.location.start_offset, node.location.start_offset + 5), srange_offsets(node.location.start_offset, node.location.start_offset + 5)))].concat(visit(node.block)), smap_collection(srange(node.block.opening_loc), srange(node.block.closing_loc), srange(node.location)))
        else
          s(:zsuper, [], smap_keyword_bare(srange(node.location), srange(node.location)))
        end
      end

      # $foo
      # ^^^^
      def visit_global_variable_read_node(node)
        s(:gvar, [node.slice.to_sym], smap_variable(srange(node.location), srange(node.location)))
      end

      # $foo = 1
      # ^^^^^^^^
      #
      # $foo, $bar = 1
      # ^^^^  ^^^^
      def visit_global_variable_write_node(node)
        if node.value
          s(:gvasgn, [node.name.to_sym, visit(node.value)], smap_variable(srange(node.name_loc), srange(node.location)).with_operator(srange(node.operator_loc)))
        else
          s(:gvasgn, [node.name.to_sym], smap_variable(srange(node.name_loc), srange(node.location)))
        end
      end

      # {}
      # ^^
      def visit_hash_node(node)
        s(:hash, visit_all(node.elements), smap_collection(srange(node.opening_loc), srange(node.closing_loc), srange(node.location)))
      end

      # foo => {}
      #        ^^
      def visit_hash_pattern_node(node)
        s(:hash_pattern, visit_all(node.assocs), smap_collection(srange(node.opening_loc), srange(node.closing_loc), srange(node.location)))
      end

      # if foo then bar end
      # ^^^^^^^^^^^^^^^^^^^
      #
      # bar if foo
      # ^^^^^^^^^^
      #
      # foo ? bar : baz
      # ^^^^^^^^^^^^^^^
      def visit_if_node(node)
        if !node.if_keyword_loc
          s(:if, [visit(node.predicate), visit(node.statements), visit(node.consequent)], smap_ternary(srange_find(node.predicate.location.end_offset, node.statements.location.start_offset, ["?"]), srange(node.consequent.else_keyword_loc), srange(node.location)))
        elsif node.if_keyword_loc.start_offset == node.location.start_offset
          begin_token = srange_find(node.predicate.location.end_offset, (node.statements&.location || node.consequent&.location || node.end_keyword_loc).start_offset, [";", "then"])
          else_token =
            case node.consequent
            when ::YARP::IfNode
              srange(node.consequent.if_keyword_loc)
            when ::YARP::ElseNode
              srange(node.consequent.else_keyword_loc)
            end

          location =
            if node.if_keyword == "elsif" && node.consequent&.statements
              smap_condition(srange(node.if_keyword_loc), begin_token, else_token, nil, srange_offsets(node.location.start_offset, node.consequent.statements.location.end_offset))
            else
              smap_condition(srange(node.if_keyword_loc), begin_token, else_token, srange(node.end_keyword_loc), srange(node.location))
            end

          s(:if, [visit(node.predicate), visit(node.statements), visit(node.consequent)], location)
        else
          s(:if, [visit(node.predicate), visit(node.statements), visit(node.consequent)], smap_keyword_bare(srange(node.if_keyword_loc), srange(node.location)))
        end
      end

      # 1i
      def visit_imaginary_node(node)
        s(:complex, [node.value], smap_operator(nil, srange(node.location)))
      end

      # case foo; in bar; end
      # ^^^^^^^^^^^^^^^^^^^^^
      def visit_in_node(node)
        s(:in_pattern, [with_context(:pattern, true) { visit(node.pattern) }, nil, visit(node.statements)], smap_keyword(srange(node.in_loc), srange_find(node.pattern.location.end_offset, (node.statements&.location || node.location).start_offset, [";"]), nil, srange(node.location)))
      end

      # @foo
      # ^^^^
      def visit_instance_variable_read_node(node)
        s(:ivar, [node.slice.to_sym], smap_variable(srange(node.location), srange(node.location)))
      end

      # @foo = 1
      # ^^^^^^^^
      #
      # @foo, @bar = 1
      # ^^^^  ^^^^
      def visit_instance_variable_write_node(node)
        if node.value
          s(:ivasgn, [node.name.to_sym, visit(node.value)], smap_variable(srange(node.name_loc), srange(node.location)).with_operator(srange(node.operator_loc)))
        else
          s(:ivasgn, [node.name.to_sym], smap_variable(srange(node.name_loc), srange(node.location)))
        end
      end

      # 1
      # ^
      def visit_integer_node(node)
        s(:int, [node.value], smap_operator(node.slice.match?(/^[+-]/) ? srange_offsets(node.location.start_offset, node.location.start_offset + 1) : nil, srange(node.location)))
      end

      # /foo #{bar}/
      # ^^^^^^^^^^^^
      def visit_interpolated_regular_expression_node(node)
        s(:regexp, visit_all(node.parts).push(s(:regopt, node.closing[1..].chars.map(&:to_sym), smap(srange_offsets(node.closing_loc.start_offset + 1, node.closing_loc.end_offset)))), smap_collection(srange(node.opening_loc), srange(node.closing_loc), srange(node.location)))
      end

      # "foo #{bar}"
      # ^^^^^^^^^^^^
      def visit_interpolated_string_node(node)
        if node.opening&.start_with?("<<")
          visit_heredoc(:dstr, node)
        elsif node.parts.length == 1 && node.parts.first.is_a?(::YARP::StringNode)
          visit(node.parts.first)
        else
          s(:dstr, visit_all(node.parts), smap_collection(srange(node.opening_loc), srange(node.closing_loc), srange(node.location)))
        end
      end

      # :"foo #{bar}"
      # ^^^^^^^^^^^^^
      def visit_interpolated_symbol_node(node)
        s(:dsym, visit_all(node.parts), smap_collection(srange(node.opening_loc), srange(node.closing_loc), srange(node.location)))
      end

      # `foo #{bar}`
      # ^^^^^^^^^^^^
      def visit_interpolated_x_string_node(node)
        if node.opening.start_with?("<<")
          visit_heredoc(:xstr, node)
        else
          s(:xstr, visit_all(node.parts), smap_collection(srange(node.opening_loc), srange(node.closing_loc), srange(node.location)))
        end
      end

      # foo(bar: baz)
      #     ^^^^^^^^
      def visit_keyword_hash_node(node)
        s(:kwargs, visit_all(node.elements), smap_collection_bare(srange(node.location)))
      end

      # def foo(bar:); end
      #         ^^^^
      #
      # def foo(bar: baz); end
      #         ^^^^^^^^
      def visit_keyword_parameter_node(node)
        if node.value
          s(:kwoptarg, [node.name.chomp(":").to_sym, visit(node.value)], smap_variable(srange_offsets(node.name_loc.start_offset, node.name_loc.end_offset - 1), srange(node.location)))
        else
          s(:kwarg, [node.name.chomp(":").to_sym], smap_variable(srange_offsets(node.name_loc.start_offset, node.name_loc.end_offset - 1), srange(node.location)))
        end
      end

      # def foo(**bar); end
      #         ^^^^^
      #
      # def foo(**); end
      #         ^^
      def visit_keyword_rest_parameter_node(node)
        if node.name
          s(:kwrestarg, [node.name.to_sym], smap_variable(srange(node.name_loc), srange(node.location)))
        else
          s(:kwrestarg, [], smap_variable(srange(node.name_loc), srange(node.location)))
        end
      end

      # -> {}
      def visit_lambda_node(node)
        s(:block, [s(:lambda, [], smap(srange(node.operator_loc))), node.parameters ? s(:args, visit(node.parameters), smap_collection(srange(node.parameters.opening_loc), srange(node.parameters.closing_loc), srange(node.parameters.location))) : s(:args, [], smap_collection_bare(nil)), with_context(:locals, node.locals) { visit(node.body) }], smap_collection(srange(node.opening_loc), srange(node.closing_loc), srange(node.location)))
      end

      # foo
      # ^^^
      def visit_local_variable_read_node(node)
        s(:lvar, [node.constant_id], smap_variable(srange(node.location), srange(node.location)))
      end

      # foo = 1
      # ^^^^^^^
      #
      # foo, bar = 1
      # ^^^  ^^^
      def visit_local_variable_write_node(node)
        if node.value
          s(context[:pattern] ? :match_var : :lvasgn, [node.constant_id, visit(node.value)], smap_variable(srange(node.name_loc), srange(node.location)).with_operator(srange(node.operator_loc)))
        else
          s(context[:pattern] ? :match_var : :lvasgn, [node.constant_id], smap_variable(srange(node.name_loc), srange(node.location)))
        end
      end

      # foo in bar
      # ^^^^^^^^^^
      def visit_match_predicate_node(node)
        s(:match_pattern_p, [visit(node.value), with_context(:pattern, true) { visit(node.pattern) }], smap_operator(srange(node.operator_loc), srange(node.location)))
      end

      # foo => bar
      # ^^^^^^^^^^
      def visit_match_required_node(node)
        s(:match_pattern, [visit(node.value), with_context(:pattern, true) { visit(node.pattern) }], smap_operator(srange(node.operator_loc), srange(node.location)))
      end

      # A node that is missing from the syntax tree. This is only used in the
      # case of a syntax error. The parser gem doesn't have such a concept, so
      # we invent our own here.
      def visit_missing_node(node)
        s(:missing, [], smap(srange(node.location)))
      end

      # module Foo; end
      # ^^^^^^^^^^^^^^^
      def visit_module_node(node)
        s(:module, [visit(node.constant_path), with_context(:locals, node.locals) { visit(node.body) }], smap_definition(srange(node.module_keyword_loc), nil, srange(node.constant_path.location), srange(node.end_keyword_loc)))
      end

      # foo, bar = baz
      def visit_multi_write_node(node)
        if (node.targets.length == 1 || (node.targets.length == 2 && node.targets.last.is_a?(::YARP::SplatNode) && node.targets.last.operator == ",")) && node.value.nil?
          visit(node.targets.first)
        else
          mlhs_location =
            if node.lparen_loc && node.rparen_loc
              srange(node.lparen_loc.to(node.rparen_loc))
            else
              srange(node.targets.first.location.to(node.targets.last.location))
            end

          mlhs = s(:mlhs, visit_all(node.targets), smap_collection(srange(node.lparen_loc), srange(node.rparen_loc), mlhs_location))
          node.value ? s(:masgn, [mlhs, visit(node.value)], smap_operator(srange(node.operator_loc), srange(node.location))) : mlhs
        end
      end

      # next
      # ^^^^
      #
      # next foo
      # ^^^^^^^^
      def visit_next_node(node)
        s(:next, visit(node.arguments), smap_keyword_bare(srange(node.keyword_loc), srange(node.location)))
      end

      # nil
      # ^^^
      def visit_nil_node(node)
        s(:nil, [], smap(srange(node.location)))
      end

      # def foo(**nil); end
      #         ^^^^^
      def visit_no_keywords_parameter_node(node)
        s(:kwnilarg, [], smap_variable(srange(node.keyword_loc), srange(node.location)))
      end

      # $1
      # ^^
      def visit_numbered_reference_read_node(node)
        s(:nth_ref, [Integer(node.slice.delete_prefix("$"))], smap(srange(node.location)))
      end

      # foo += bar
      # ^^^^^^^^^^
      def visit_operator_write_node(node)
        case node.target
        when ::YARP::ConstantPathWriteNode
          s(:op_asgn, [visit(node.target), node.operator, visit(node.value)], smap_constant(srange(node.target.target.delimiter_loc), srange(node.target.target.child.location), srange(node.location)).with_operator(srange(node.operator_loc)))
        when ::YARP::ConstantWriteNode
          s(:op_asgn, [visit(node.target), node.operator, visit(node.value)], smap_constant(nil, srange(node.target.name_loc), srange(node.location)).with_operator(srange(node.operator_loc)))
        else
          s(:op_asgn, [visit(node.target), node.operator, visit(node.value)], smap_variable(srange(node.target.location), srange(node.location)).with_operator(srange(node.operator_loc)))
        end
      end

      # def foo(bar = 1); end
      #         ^^^^^^^
      def visit_optional_parameter_node(node)
        s(:optarg, [node.constant_id, visit(node.value)], smap_variable(srange(node.name_loc), srange(node.location)).with_operator(srange(node.operator_loc)))
      end

      # a or b
      # ^^^^^^
      def visit_or_node(node)
        s(:or, [visit(node.left), visit(node.right)], smap_operator(srange(node.operator_loc), srange(node.location)))
      end

      # a ||= b
      # ^^^^^^^
      def visit_or_write_node(node)
        case node.target
        when ::YARP::ConstantPathWriteNode
          s(:or_asgn, [visit(node.target), visit(node.value)], smap_constant(srange(node.target.target.delimiter_loc), srange(node.target.target.child.location), srange(node.location)).with_operator(srange(node.operator_loc)))
        else
          s(:or_asgn, [visit(node.target), visit(node.value)], smap_variable(srange(node.target.location), srange(node.location)).with_operator(srange(node.operator_loc)))
        end
      end

      # def foo(bar, *baz); end
      #         ^^^^^^^^^
      def visit_parameters_node(node)
        params = []
        params.concat(visit_all(node.requireds)) if node.requireds.any?
        params.concat(visit_all(node.optionals)) if node.optionals.any?
        params << visit(node.rest) if !node.rest.nil? && node.rest.operator != ","
        params.concat(visit_all(node.posts)) if node.posts.any?
        params.concat(visit_all(node.keywords)) if node.keywords.any?
        params << visit(node.keyword_rest) if !node.keyword_rest.nil?
        params << visit(node.block) if !node.block.nil?
        params
      end

      # ()
      # ^^
      #
      # (1)
      # ^^^
      def visit_parentheses_node(node)
        location = smap_collection(srange(node.opening_loc), srange(node.closing_loc), srange(node.location))
        
        if node.body.nil?
          s(:begin, [], location)
        else
          child = visit(node.body)

          if child.type == :begin
            s(:begin, child.children, location)
          else
            s(:begin, [child], location)
          end
        end
      end

      # foo => ^(bar)
      #        ^^^^^^
      def visit_pinned_expression_node(node)
        s(:pin, [s(:begin, [visit(node.expression)], smap_collection(srange(node.lparen_loc), srange(node.rparen_loc), srange(node.lparen_loc.to(node.rparen_loc))))], smap_send_bare(srange(node.operator_loc), srange(node.location)))
      end

      # foo = 1 and bar => ^foo
      #                    ^^^^
      def visit_pinned_variable_node(node)
        s(:pin, [visit(node.variable)], smap_send_bare(srange(node.operator_loc), srange(node.location)))
      end

      # END {}
      def visit_post_execution_node(node)
        s(:postexe, [visit(node.statements)], smap_keyword(srange(node.keyword_loc), srange(node.opening_loc), srange(node.closing_loc), srange(node.location)))
      end

      # BEGIN {}
      def visit_pre_execution_node(node)
        s(:preexe, [visit(node.statements)], smap_keyword(srange(node.keyword_loc), srange(node.opening_loc), srange(node.closing_loc), srange(node.location)))
      end

      # The top-level program node.
      def visit_program_node(node)
        case node.statements.body.length
        when 0
          # nothing
        when 1
          visit_top_level(node.statements.body.first)
        else
          s(:begin, node.statements.body.map { visit_top_level(_1) }, smap_collection_bare(srange(node.location)))
        end
      end

      # 0..5
      # ^^^^
      def visit_range_node(node)
        s(node.exclude_end? ? :erange : :irange, [visit(node.left), visit(node.right)], smap_operator(srange(node.operator_loc), srange(node.location)))
      end

      # 1r
      # ^^
      def visit_rational_node(node)
        s(:rational, [node.value], smap_operator(nil, srange(node.location)))
      end

      # redo
      # ^^^^
      def visit_redo_node(node)
        s(:redo, [], smap_keyword_bare(srange(node.location), srange(node.location)))
      end

      # /foo/
      # ^^^^^
      def visit_regular_expression_node(node)
        s(:regexp, [s(:str, [node.content], smap_collection_bare(srange(node.content_loc))), s(:regopt, node.closing[1..].chars.map(&:to_sym), smap(srange_offsets(node.closing_loc.start_offset + 1, node.closing_loc.end_offset)))], smap_collection(srange(node.opening_loc), srange_offsets(node.closing_loc.start_offset, node.closing_loc.start_offset + 1), srange(node.location)))
      end

      # def foo((bar)); end
      #         ^^^^^
      def visit_required_destructured_parameter_node(node)
        s(:mlhs, with_context(:destructured, true) { visit_all(node.parameters) }, smap_collection(srange(node.opening_loc), srange(node.closing_loc), srange(node.location)))
      end

      # def foo(bar); end
      #         ^^^
      def visit_required_parameter_node(node)
        s(:arg, [node.constant_id], smap_variable(srange(node.location), srange(node.location)))
      end

      # foo rescue bar
      # ^^^^^^^^^^^^^^
      def visit_rescue_modifier_node(node)
        s(:rescue, [visit(node.expression), s(:resbody, [nil, nil, visit(node.rescue_expression)], smap_rescue_body(srange(node.keyword_loc), nil, nil, srange(node.keyword_loc.to(node.rescue_expression.location)))), nil], smap_condition_bare(srange(node.location)))
      end

      # begin; rescue; end
      #        ^^^^^^^
      def visit_rescue_node(node)
        resbody_children = [
          node.exceptions.any? ? s(:array, visit_all(node.exceptions), smap_collection_bare(srange_offsets(node.exceptions.first.location.start_offset, node.exceptions.last.location.end_offset))) : nil,
          node.reference ? visit(node.reference) : nil,
          visit(node.statements)
        ]

        find_start_offset = (node.reference&.location || node.exceptions.last&.location || node.keyword_loc).end_offset
        find_end_offset = (node.statements&.location&.start_offset || node.consequent&.location&.start_offset || (find_start_offset + 1))

        children = [s(:resbody, resbody_children, smap_rescue_body(srange(node.keyword_loc), srange(node.operator_loc), srange_find(find_start_offset, find_end_offset, [";"]), srange(node.location)))]
        if node.consequent
          children.concat(visit(node.consequent).children)
        else
          children << nil
        end

        s(:rescue, children, smap_condition_bare(srange(node.location)))
      end

      # def foo(*bar); end
      #         ^^^^
      #
      # def foo(*); end
      #         ^
      def visit_rest_parameter_node(node)
        s(:restarg, node.name ? [node.name.to_sym] : [], smap_variable(srange(node.name_loc), srange(node.location)))
      end

      # retry
      # ^^^^^
      def visit_retry_node(node)
        s(:retry, [], smap_keyword_bare(srange(node.location), srange(node.location)))
      end

      # return
      # ^^^^^^
      #
      # return 1
      # ^^^^^^^^
      def visit_return_node(node)
        s(:return, visit(node.arguments), smap_keyword_bare(srange(node.keyword_loc), srange(node.location)))
      end

      # self
      # ^^^^
      def visit_self_node(node)
        s(:self, [], smap(srange(node.location)))
      end

      # class << self; end
      # ^^^^^^^^^^^^^^^^^^
      def visit_singleton_class_node(node)
        s(:sclass, [visit(node.expression), with_context(:locals, node.locals) { visit(node.body) }], smap_definition(srange(node.class_keyword_loc), srange(node.operator_loc), nil, srange(node.end_keyword_loc)))
      end

      # __ENCODING__
      # ^^^^^^^^^^^^
      def visit_source_encoding_node(node)
        s(:__ENCODING__, [], smap(srange(node.location)))
      end

      # __FILE__
      # ^^^^^^^^
      def visit_source_file_node(node)
        s(:str, [buffer.name], smap(srange(node.location)))
      end

      # __LINE__
      # ^^^^^^^^
      def visit_source_line_node(node)
        s(:int, [node.location.start_line], smap(srange(node.location)))
      end

      # foo(*bar)
      #     ^^^^
      #
      # def foo((bar, *baz)); end
      #               ^^^^
      #
      # def foo(*); bar(*); end
      #                 ^
      def visit_splat_node(node)
        if node.expression.nil? && context[:locals].include?(:*)
          s(:forwarded_restarg, [], smap(srange(node.location)))
        elsif context[:destructured]
          if node.expression
            s(:restarg, [node.expression.constant_id], smap_variable(srange(node.expression.location), srange(node.location)))
          else
            s(:restarg, [], smap_variable(nil, srange(node.location)))
          end
        else
          if node.expression
            s(:splat, [visit(node.expression)], smap_operator(srange(node.operator_loc), srange(node.location)))
          else
            s(:splat, [], smap_operator(srange(node.operator_loc), srange(node.location)))
          end
        end
      end

      # A list of statements.
      def visit_statements_node(node)
        case node.body.length
        when 0
          # nothing
        when 1
          visit(node.body.first)
        else
          s(:begin, visit_all(node.body), smap_collection_bare(srange(node.location)))
        end
      end

      # "foo" "bar"
      # ^^^^^^^^^^^
      def visit_string_concat_node(node)
        s(:dstr, [visit(node.left), visit(node.right)], smap_collection_bare(srange(node.location)))
      end

      # "foo"
      # ^^^^^
      def visit_string_node(node)
        s(:str, [node.unescaped], smap_collection(srange(node.opening_loc), srange(node.closing_loc), srange(node.location)))
      end

      # super(foo)
      # ^^^^^^^^^^
      def visit_super_node(node)
        if node.block
          s(:block, [s(:super, visit(node.arguments), smap_keyword(srange(node.keyword_loc), srange(node.lparen_loc), srange(node.rparen_loc), srange_offsets(node.location.start_offset, (node.rparen_loc || node.arguments.location).end_offset)))].concat(visit(node.block)), smap_collection(srange(node.block.opening_loc), srange(node.block.closing_loc), srange(node.location)))
        else
          s(:super, visit(node.arguments), smap_keyword(srange(node.keyword_loc), srange(node.lparen_loc), srange(node.rparen_loc), srange(node.location)))
        end
      end

      # :foo
      # ^^^^
      def visit_symbol_node(node)
        s(:sym, [node.unescaped.to_sym], smap_collection(srange(node.opening_loc), srange(node.closing_loc), srange(node.location)))
      end

      # true
      # ^^^^
      def visit_true_node(node)
        s(:true, [], smap(srange(node.location)))
      end

      # undef foo
      # ^^^^^^^^^
      def visit_undef_node(node)
        s(:undef, visit_all(node.names), smap_keyword(srange(node.keyword_loc), nil, nil, srange(node.location)))
      end

      # unless foo; bar end
      # ^^^^^^^^^^^^^^^^^^^
      #
      # bar unless foo
      # ^^^^^^^^^^^^^^
      def visit_unless_node(node)
        if node.keyword_loc.start_offset == node.location.start_offset
          s(:if, [visit(node.predicate), visit(node.consequent), visit(node.statements)], smap_condition(srange(node.keyword_loc), srange_find(node.predicate.location.end_offset, (node.statements&.location || node.consequent&.location || node.end_keyword_loc).start_offset, [";", "then"]), node.consequent ? srange(node.consequent.else_keyword_loc) : nil, srange(node.end_keyword_loc), srange(node.location)))
        else
          s(:if, [visit(node.predicate), visit(node.consequent), visit(node.statements)], smap_keyword_bare(srange(node.keyword_loc), srange(node.location)))
        end
      end

      # until foo; bar end
      # ^^^^^^^^^^^^^^^^^
      #
      # bar until foo
      # ^^^^^^^^^^^^^
      def visit_until_node(node)
        if node.location.start_offset == node.keyword_loc.start_offset
          s(:until, [visit(node.predicate), visit(node.statements)], smap_keyword(srange(node.keyword_loc), srange_find(node.predicate.location.end_offset, (node.statements&.location || node.closing_loc).start_offset, [";", "do"]), srange(node.closing_loc), srange(node.location)))
        else
          s(node.begin_modifier? ? :until_post : :until, [visit(node.predicate), visit(node.statements)], smap_keyword(srange(node.keyword_loc), nil, srange(node.closing_loc), srange(node.location)))
        end
      end

      # case foo; when bar; end
      #           ^^^^^^^^^^^^^
      def visit_when_node(node)
        s(:when, visit_all(node.conditions).push(visit(node.statements)), smap_keyword(srange(node.keyword_loc), srange_find(node.conditions.last.location.end_offset, node.statements&.location&.start_offset || (node.conditions.last.location.end_offset + 1), [";", "then"]), nil, srange(node.location)))
      end

      # while foo; bar end
      # ^^^^^^^^^^^^^^^^^^
      #
      # bar while foo
      # ^^^^^^^^^^^^^
      def visit_while_node(node)
        if node.location.start_offset == node.keyword_loc.start_offset
          s(:while, [visit(node.predicate), visit(node.statements)], smap_keyword(srange(node.keyword_loc), srange_find(node.predicate.location.end_offset, (node.statements&.location || node.closing_loc).start_offset, [";", "do"]), srange(node.closing_loc), srange(node.location)))
        else
          s(node.begin_modifier? ? :while_post : :while, [visit(node.predicate), visit(node.statements)], smap_keyword(srange(node.keyword_loc), nil, srange(node.closing_loc), srange(node.location)))
        end
      end

      # `foo`
      # ^^^^^
      def visit_x_string_node(node)
        s(:xstr, [s(:str, [node.unescaped], smap_collection_bare(srange(node.content_loc)))], smap_collection(srange(node.opening_loc), srange(node.closing_loc), srange(node.location)))
      end

      # yield
      # ^^^^^
      #
      # yield 1
      # ^^^^^^^
      def visit_yield_node(node)
        if node.arguments
          s(:yield, visit(node.arguments), smap_keyword(srange(node.keyword_loc), srange(node.lparen_loc), srange(node.rparen_loc), srange(node.location)))
        else
          s(:yield, [], smap_keyword(srange(node.keyword_loc), srange(node.lparen_loc), srange(node.rparen_loc), srange(node.location)))
        end
      end

      private

      # Blocks can have a special set of parameters that automatically expand
      # when given arrays if they have a single required parameter and no other
      # parameters.
      def procarg0(block_parameters)
        if (parameters = block_parameters.parameters) &&
           parameters.requireds.length == 1 &&
           (parameter = parameters.requireds.first) &&
           parameters.optionals.empty? &&
           parameters.rest.nil? &&
           parameters.posts.empty? &&
           parameters.keywords.empty? &&
           parameters.keyword_rest.nil? &&
           parameters.block.nil? &&
           block_parameters.locals.empty?

          location = smap_collection(srange(block_parameters.opening_loc), srange(block_parameters.closing_loc), srange(block_parameters.location))

          if parameter.is_a?(::YARP::RequiredParameterNode)
            s(:args, [s(:procarg0, [visit(parameter)], smap_collection_bare(srange(parameter.location)))], location)
          else
            visited = visit(parameter)
            s(:args, [s(:procarg0, visited.children, visited.location)], location)
          end
        end
      end

      # Create a new parser node.
      def s(type, children = [], location = nil)
        AST::Node.new(type, children, location: location)
      end

      # Constructs a plain source map just for an expression.
      def smap(expression)
        Source::Map.new(expression)
      end

      # Constructs a new source map for a collection.
      def smap_collection(begin_token, end_token, expression)
        Source::Map::Collection.new(begin_token, end_token, expression)
      end

      # Constructs a new source map for a collection without a begin or end.
      def smap_collection_bare(expression)
        smap_collection(nil, nil, expression)
      end

      # Constructs a new source map for a conditional expression.
      def smap_condition(keyword, begin_token, else_token, end_token, expression)
        Source::Map::Condition.new(keyword, begin_token, else_token, end_token, expression)
      end

      # Constructs a new source map for a conditional expression with no begin
      # or end.
      def smap_condition_bare(expression)
        smap_condition(nil, nil, nil, nil, expression)
      end

      # Constructs a new source map for a constant reference.
      def smap_constant(double_colon, name, expression)
        Source::Map::Constant.new(double_colon, name, expression)
      end

      # Constructs a new source map for a class definition.
      def smap_definition(keyword, operator, name, end_token)
        Source::Map::Definition.new(keyword, operator, name, end_token)
      end

      # Constructs a new source map for a for loop.
      def smap_for(keyword, in_token, begin_token, end_token, expression)
        Source::Map::For.new(keyword, in_token, begin_token, end_token, expression)
      end

      # Constructs a new source map for a heredoc.
      def smap_heredoc(expression, heredoc_body, heredoc_end)
        Source::Map::Heredoc.new(expression, heredoc_body, heredoc_end)
      end

      # Construct a source map for an index operation.
      def smap_index(begin_token, end_token, expression)
        Source::Map::Index.new(begin_token, end_token, expression)
      end

      # Constructs a new source map for the use of a keyword.
      def smap_keyword(keyword, begin_token, end_token, expression)
        Source::Map::Keyword.new(keyword, begin_token, end_token, expression)
      end

      # Constructs a new source map for the use of a keyword without a begin or
      # end token.
      def smap_keyword_bare(keyword, expression)
        smap_keyword(keyword, nil, nil, expression)
      end

      # Constructs a new source map for a method definition.
      def smap_method_definition(keyword, operator, name, end_token, assignment, expression)
        Source::Map::MethodDefinition.new(keyword, operator, name, end_token, assignment, expression)
      end

      # Constructs a new source map for an operator.
      def smap_operator(operator, expression)
        Source::Map::Operator.new(operator, expression)
      end

      # Constructs a source map for the body of a rescue clause.
      def smap_rescue_body(keyword, assoc, begin_token, expression)
        Source::Map::RescueBody.new(keyword, assoc, begin_token, expression)
      end

      # Constructs a new source map for a method call.
      def smap_send(dot, selector, begin_token, end_token, expression)
        Source::Map::Send.new(dot, selector, begin_token, end_token, expression)
      end

      # Constructs a new source map for a method call without a begin or end.
      def smap_send_bare(selector, expression)
        smap_send(nil, selector, nil, nil, expression)
      end

      # Constructs a new source map for a ternary expression.
      def smap_ternary(question, colon, expression)
        Source::Map::Ternary.new(question, colon, expression)
      end

      # Constructs a new source map for a variable.
      def smap_variable(name, expression)
        Source::Map::Variable.new(name, expression)
      end

      # Constructs a new source range from the given start and end offsets.
      def srange(location)
        Source::Range.new(buffer, location.start_offset, location.end_offset) if location
      end

      # Constructs a new source range by finding the given tokens between the
      # given start offset and end offset. If the needle is not found, it
      # returns nil.
      def srange_find(start_offset, end_offset, tokens)
        tokens.find do |token|
          next unless (index = buffer.source.byteslice(start_offset...end_offset).index(token))
          offset = start_offset + index
          return Source::Range.new(buffer, offset, offset + token.length)
        end
      end

      # Constructs a new source range from the given start and end offsets.
      def srange_offsets(start_offset, end_offset)
        Source::Range.new(buffer, start_offset, end_offset)
      end

      # Visit the target of a call operator write node.
      def visit_call_operator_write(node)
        target = visit(node)

        case node.name
        when "[]="
          s(target.type, target.children, smap_index(srange_offsets(node.message_loc.start_offset, node.message_loc.start_offset + 1), srange_offsets(node.message_loc.end_offset - 1, node.message_loc.end_offset), srange(node.location)))
        else
          children = [*target.children]
          children[1] = children[1].name.chomp("=").to_sym
          s(target.type, children, smap_send(srange(node.operator_loc), srange(node.message_loc), nil, nil, srange(node.location)))
        end
      end

      # Visit a heredoc that can be either a string or an xstring.
      def visit_heredoc(type, node)
        children = []
        node.parts.each do |part|
          pushing =
            if part.is_a?(::YARP::StringNode) && part.unescaped.count("\n") > 1
              unescaped = part.unescaped.split("\n")
              escaped = part.content.split("\n")

              escaped_lengths =
                if node.opening.end_with?("'")
                  escaped.map { |line| line.bytesize + 1 }
                else
                  escaped.chunk_while { |before, after| before.match?(/(?<!\\)\\$/) }.map { |line| line.join.bytesize + line.length }
                end

              start_offset = part.location.start_offset
              end_offset = nil

              unescaped.zip(escaped_lengths).map do |unescaped_line, escaped_length|
                end_offset = start_offset + escaped_length
                s(:str, ["#{unescaped_line}\n"], smap_collection_bare(srange_offsets(start_offset, end_offset))).tap do
                  start_offset = end_offset
                end
              end
            else
              [visit(part)]
            end

          pushing.each do |child|
            if child.type == :str && children.last && children.last.type == :str && !children.last.children.first.end_with?("\n")
              children.last.children.first << child.children.first
            else
              children << child
            end
          end
        end

        location =
          smap_heredoc(
            srange(node.location),
            srange_offsets(srange_find(node.opening_loc.end_offset, node.closing_loc.start_offset, ["\n"]).end_pos, node.closing_loc.start_offset),
            srange_offsets(node.closing_loc.start_offset, node.closing_loc.end_offset - node.closing[/\s+$/].length)
          )

        if type != :xstr && children.length == 1
          s(children.first.type, children.first.children, location)
        else
          s(type, children, location)
        end
      end

      # Visit a statement at the top level of the file.
      def visit_top_level(node)
        if node.is_a?(::YARP::IfNode) && node.predicate.is_a?(::YARP::RegularExpressionNode)
          visited = visit(node)
          children = [s(:match_current_line, [visited.children[0]], smap(srange(node.predicate.location))), *visited.children[1..]]
          s(visited.type, children, visited.location)
        elsif node.is_a?(::YARP::CallNode) && node.name == "!" && node.receiver.is_a?(::YARP::RegularExpressionNode) && !node.arguments && !node.block
          visited = visit(node)
          children = [s(:match_current_line, [visited.children[0]], smap(srange(node.receiver.location))), *visited.children[1..]]
          s(visited.type, children, visited.location)
        else
          visit(node)
        end
      end

      # Within the given block, set the given context key to the given value.
      def with_context(key, value)
        previous = context[key]
        context[key] = value

        begin
          yield
        ensure
          context[key] = previous
        end
      end
    end

    # Parse the contents of the given buffer and return the AST.
    def self.parse(buffer)
      ::YARP.parse(buffer.source, buffer.name).value.accept(Visitor.new(buffer))
    end

    # Compare the ASTs between the translator and the whitequark/parser gem.
    def self.compare(filepath, source = nil)
      buffer = Source::Buffer.new(filepath, 1)
      buffer.source = source || File.read(filepath)

      parser = CurrentRuby.default_parser
      parser.diagnostics.consumer = ->(*) {}
      parser.diagnostics.all_errors_are_fatal = true

      expected = parser.parse(buffer)
      actual = parse(buffer)
      return true if expected == actual

      puts filepath
      queue = [[expected, actual]]

      while (left, right = queue.shift)
        if left.type != right.type
          puts "expected:"
          pp left
    
          puts "actual:"
          pp right
    
          return false
        end
    
        if left.location != right.location
          puts "expected:"
          pp left
          pp left.location
    
          puts "actual:"
          pp right
          pp right.location
    
          return false
        end
    
        left.children.zip(right.children).each do |left_child, right_child|
          queue << [left_child, right_child] if left_child.is_a?(Parser::AST::Node)
        end
      end

      false
    end
  end
end

# Validate that the visitor has a visit method for each node type and only those
# node types.
expected = YARP.constants.grep(/.Node$/).map(&:name)
actual =
  Parser::YARP::Visitor.instance_methods(false).grep(/^visit_/).map do
    _1[6..].split("_").map(&:capitalize).join
  end

if (extra = actual - expected).any?
  raise "Unexpected visit methods for: #{extra.join(", ")}"
end

if (missing = expected - actual).any?
  raise "Missing visit methods for: #{missing.join(", ")}"
end
