# frozen_string_literal: true

module Parser
  class Prism
    class Compiler < ::Prism::Compiler
      attr_reader :parser, :builder, :source_buffer
      attr_reader :context_locals, :context_destructure, :context_pattern

      def initialize(parser)
        @parser = parser
        @builder = parser.builder
        @source_buffer = parser.source_buffer

        @context_locals = nil
        @context_destructure = false
        @context_pattern = false
      end

      # alias foo bar
      # ^^^^^^^^^^^^^
      def visit_alias_method_node(node)
        builder.alias(token(node.keyword_loc), visit(node.new_name), visit(node.old_name))
      end

      # alias $foo $bar
      # ^^^^^^^^^^^^^^^
      def visit_alias_global_variable_node(node)
        builder.alias(token(node.keyword_loc), visit(node.new_name), visit(node.old_name))
      end

      # foo => bar | baz
      #        ^^^^^^^^^
      def visit_alternation_pattern_node(node)
        builder.match_alt(visit(node.left), token(node.operator_loc), visit(node.right))
      end

      # a and b
      # ^^^^^^^
      def visit_and_node(node)
        builder.logical_op(:and, visit(node.left), token(node.operator_loc), visit(node.right))
      end

      # []
      # ^^
      def visit_array_node(node)
        builder.array(token(node.opening_loc), visit_all(node.elements), token(node.closing_loc))
      end

      # foo => [bar]
      #        ^^^^^
      def visit_array_pattern_node(node)
        if node.constant
          builder.const_pattern(visit(node.constant), token(node.opening_loc), builder.array_pattern(nil, visit_all([*node.requireds, *node.rest, *node.posts]), nil), token(node.closing_loc))
        else
          builder.array_pattern(token(node.opening_loc), visit_all([*node.requireds, *node.rest, *node.posts]), token(node.closing_loc))
        end
      end

      # foo(bar)
      #     ^^^
      def visit_arguments_node(node)
        visit_all(node.arguments)
      end

      # { a: 1 }
      #   ^^^^
      def visit_assoc_node(node)
        if node.value.is_a?(::Prism::ImplicitNode)
          builder.pair_label([node.key.slice.chomp(":"), srange(node.key.location)])
        elsif context_pattern && node.value.nil?
          if node.key.is_a?(::Prism::SymbolNode)
            builder.match_hash_var([node.key.unescaped, srange(node.key.location)])
          else
            builder.match_hash_var_from_str(token(node.key.opening_loc), visit_all(node.key.parts), token(node.key.closing_loc))
          end
        elsif node.operator_loc
          builder.pair(visit(node.key), token(node.operator_loc), visit(node.value))
        elsif node.key.is_a?(::Prism::SymbolNode) && node.key.opening_loc.nil?
          builder.pair_keyword([node.key.unescaped, srange(node.key.location)], visit(node.value))
        else
          parts =
            if node.key.is_a?(::Prism::SymbolNode)
              [builder.string_internal([node.key.unescaped, srange(node.key.value_loc)])]
            else
              visit_all(node.key.parts)
            end

          builder.pair_quoted(token(node.key.opening_loc), parts, token(node.key.closing_loc), visit(node.value))
        end
      end

      # def foo(**); bar(**); end
      #                  ^^
      #
      # { **foo }
      #   ^^^^^
      def visit_assoc_splat_node(node)
        if node.value.nil? && context_locals.include?(:**)
          builder.forwarded_kwrestarg(token(node.operator_loc))
        else
          builder.kwsplat(token(node.operator_loc), visit(node.value))
        end
      end

      # $+
      # ^^
      def visit_back_reference_read_node(node)
        builder.back_ref(token(node.location))
      end

      # begin end
      # ^^^^^^^^^
      def visit_begin_node(node)
        rescue_bodies = []

        if (rescue_clause = node.rescue_clause)
          begin
            find_start_offset = (rescue_clause.reference&.location || rescue_clause.exceptions.last&.location || rescue_clause.keyword_loc).end_offset
            find_end_offset = (rescue_clause.statements&.location&.start_offset || rescue_clause.consequent&.location&.start_offset || (find_start_offset + 1))

            rescue_bodies << builder.rescue_body(
              token(rescue_clause.keyword_loc),
              rescue_clause.exceptions.any? ? builder.array(nil, visit_all(rescue_clause.exceptions), nil) : nil,
              token(rescue_clause.operator_loc),
              visit(rescue_clause.reference),
              srange_find(find_start_offset, find_end_offset, [";"]),
              visit(rescue_clause.statements)
            )
          end until (rescue_clause = rescue_clause.consequent).nil?
        end

        begin_body =
          builder.begin_body(
            visit(node.statements),
            rescue_bodies,
            token(node.else_clause&.else_keyword_loc),
            visit(node.else_clause),
            token(node.ensure_clause&.ensure_keyword_loc),
            visit(node.ensure_clause&.statements)
          )

        if node.begin_keyword_loc
          builder.begin_keyword(token(node.begin_keyword_loc), begin_body, token(node.end_keyword_loc))
        else
          begin_body
        end
      end

      # foo(&bar)
      #     ^^^^
      def visit_block_argument_node(node)
        builder.block_pass(token(node.operator_loc), visit(node.expression))
      end

      # foo { |; bar| }
      #          ^^^
      def visit_block_local_variable_node(node)
        builder.shadowarg(token(node.location))
      end

      # A block on a keyword or method call.
      def visit_block_node(node)
        raise "Cannot directly compile block nodes"
      end

      # def foo(&bar); end
      #         ^^^^
      def visit_block_parameter_node(node)
        builder.blockarg(token(node.operator_loc), token(node.name_loc))
      end

      # A block's parameters.
      def visit_block_parameters_node(node)
        [*visit(node.parameters)].concat(visit_all(node.locals))
      end

      # break
      # ^^^^^
      #
      # break foo
      # ^^^^^^^^^
      def visit_break_node(node)
        builder.keyword_cmd(:break, token(node.keyword_loc), nil, visit(node.arguments) || [], nil)
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
        arguments = node.arguments&.arguments || []
        block = node.block

        if block.is_a?(::Prism::BlockArgumentNode)
          arguments = [*arguments, block]
          block = nil
        end

        visit_block(
          if node.message == "not" || node.message == "!"
            builder.not_op(
              token(node.message_loc),
              token(node.opening_loc),
              visit(node.receiver),
              token(node.closing_loc)
            )
          elsif node.name == "[]"
            builder.index(
              visit(node.receiver),
              token(node.opening_loc),
              visit_all(arguments),
              token(node.closing_loc)
            )
          elsif node.name == "[]=" && node.message != "[]=" && node.arguments && node.block.nil?
            builder.assign(
              builder.index_asgn(
                visit(node.receiver),
                token(node.opening_loc),
                visit_all(node.arguments.arguments[...-1]),
                token(node.closing_loc),
              ),
              srange_find(node.message_loc.end_offset, node.arguments.arguments.last.location.start_offset, ["="]),
              visit(node.arguments.arguments.last)
            )
          elsif node.name.end_with?("=") && !node.message.end_with?("=") && node.arguments && node.block.nil?
            builder.assign(
              builder.attr_asgn(
                visit(node.receiver),
                node.call_operator_loc ? [{ "." => :dot, "&." => :anddot, "::" => "::" }.fetch(node.call_operator), srange(node.call_operator_loc)] : nil,
                token(node.message_loc)
              ),
              srange_find(node.message_loc.end_offset, node.arguments.location.start_offset, ["="]),
              visit(node.arguments.arguments.last)
            )
          else
            builder.call_method(
              visit(node.receiver),
              node.call_operator_loc ? [{ "." => :dot, "&." => :anddot, "::" => "::" }.fetch(node.call_operator), srange(node.call_operator_loc)] : nil,
              node.message_loc ? [node.name, srange(node.message_loc)] : nil,
              token(node.opening_loc),
              visit_all(arguments),
              token(node.closing_loc)
            )
          end,
          block
        )
      end

      # foo.bar += baz
      # ^^^^^^^^^^^^^^^
      #
      # foo[bar] += baz
      # ^^^^^^^^^^^^^^^
      def visit_call_operator_write_node(node)
        builder.op_assign(
          if node.read_name == "[]"
            builder.index(
              visit(node.receiver),
              token(node.opening_loc),
              visit(node.arguments) || [],
              token(node.closing_loc)
            )
          else
            builder.call_method(
              visit(node.receiver),
              node.call_operator_loc ? [{ "." => :dot, "&." => :anddot, "::" => "::" }.fetch(node.call_operator), srange(node.call_operator_loc)] : nil,
              node.message_loc ? [node.read_name, srange(node.message_loc)] : nil,
              token(node.opening_loc),
              visit(node.arguments) || [],
              token(node.closing_loc)
            )
          end,
          [node.operator_loc.slice.chomp("="), srange(node.operator_loc)],
          visit(node.value)
        )
      end

      # foo.bar &&= baz
      # ^^^^^^^^^^^^^^^
      #
      # foo[bar] &&= baz
      # ^^^^^^^^^^^^^^^^
      alias visit_call_and_write_node visit_call_operator_write_node

      # foo.bar ||= baz
      # ^^^^^^^^^^^^^^^
      #
      # foo[bar] ||= baz
      # ^^^^^^^^^^^^^^^^
      alias visit_call_or_write_node visit_call_operator_write_node

      # foo => bar => baz
      #        ^^^^^^^^^^
      def visit_capture_pattern_node(node)
        builder.match_as(visit(node.value), token(node.operator_loc), visit(node.target))
      end

      # case foo; when bar; end
      # ^^^^^^^^^^^^^^^^^^^^^^^
      #
      # case foo; in bar; end
      # ^^^^^^^^^^^^^^^^^^^^^
      def visit_case_node(node)
        builder.public_send(
          node.conditions.first.is_a?(::Prism::WhenNode) ? :case : :case_match,
          token(node.case_keyword_loc),
          visit(node.predicate),
          visit_all(node.conditions),
          token(node.consequent&.else_keyword_loc),
          visit(node.consequent),
          token(node.end_keyword_loc)
        )
      end

      # class Foo; end
      # ^^^^^^^^^^^^^^
      def visit_class_node(node)
        builder.def_class(
          token(node.class_keyword_loc),
          visit(node.constant_path),
          token(node.inheritance_operator_loc),
          visit(node.superclass),
          with_locals(node.locals) { visit(node.body) },
          token(node.end_keyword_loc)
        )
      end

      # @@foo
      # ^^^^^
      def visit_class_variable_read_node(node)
        builder.cvar(token(node.location))
      end

      # @@foo = 1
      # ^^^^^^^^^
      #
      # @@foo, @@bar = 1
      # ^^^^^  ^^^^^
      def visit_class_variable_write_node(node)
        builder.assign(
          builder.assignable(builder.cvar(token(node.name_loc))),
          token(node.operator_loc),
          visit(node.value)
        )
      end

      # @@foo += bar
      # ^^^^^^^^^^^^
      def visit_class_variable_operator_write_node(node)
        builder.op_assign(
          builder.assignable(builder.cvar(token(node.name_loc))),
          [node.operator_loc.slice.chomp("="), srange(node.operator_loc)],
          visit(node.value)
        )
      end

      # @@foo &&= bar
      # ^^^^^^^^^^^^^
      alias visit_class_variable_and_write_node visit_class_variable_operator_write_node

      # @@foo ||= bar
      # ^^^^^^^^^^^^^
      alias visit_class_variable_or_write_node visit_class_variable_operator_write_node

      # @@foo, = bar
      # ^^^^^
      def visit_class_variable_target_node(node)
        builder.assignable(builder.cvar(token(node.location)))
      end

      # Foo
      # ^^^
      def visit_constant_read_node(node)
        builder.const([node.name, srange(node.location)])
      end

      # Foo = 1
      # ^^^^^^^
      #
      # Foo, Bar = 1
      # ^^^  ^^^
      def visit_constant_write_node(node)
        builder.assign(builder.assignable(builder.const([node.name, srange(node.name_loc)])), token(node.operator_loc), visit(node.value))
      end

      # Foo += bar
      # ^^^^^^^^^^^
      def visit_constant_operator_write_node(node)
        builder.op_assign(
          builder.assignable(builder.const([node.name, srange(node.name_loc)])),
          [node.operator_loc.slice.chomp("="), srange(node.operator_loc)],
          visit(node.value)
        )
      end

      # Foo &&= bar
      # ^^^^^^^^^^^^
      alias visit_constant_and_write_node visit_constant_operator_write_node

      # Foo ||= bar
      # ^^^^^^^^^^^^
      alias visit_constant_or_write_node visit_constant_operator_write_node

      # Foo, = bar
      # ^^^
      def visit_constant_target_node(node)
        builder.assignable(builder.const([node.name, srange(node.location)]))
      end

      # Foo::Bar
      # ^^^^^^^^
      def visit_constant_path_node(node)
        if node.parent.nil?
          builder.const_global(
            token(node.delimiter_loc),
            [node.child.name, srange(node.child.location)]
          )
        else
          builder.const_fetch(
            visit(node.parent),
            token(node.delimiter_loc),
            [node.child.name, srange(node.child.location)]
          )
        end
      end

      # Foo::Bar = 1
      # ^^^^^^^^^^^^
      #
      # Foo::Foo, Bar::Bar = 1
      # ^^^^^^^^  ^^^^^^^^
      def visit_constant_path_write_node(node)
        builder.assign(
          builder.assignable(visit(node.target)),
          token(node.operator_loc),
          visit(node.value)
        )
      end

      # Foo::Bar += baz
      # ^^^^^^^^^^^^^^^
      def visit_constant_path_operator_write_node(node)
        builder.op_assign(
          builder.assignable(visit(node.target)),
          [node.operator_loc.slice.chomp("="), srange(node.operator_loc)],
          visit(node.value)
        )
      end

      # Foo::Bar &&= baz
      # ^^^^^^^^^^^^^^^^
      alias visit_constant_path_and_write_node visit_constant_path_operator_write_node

      # Foo::Bar ||= baz
      # ^^^^^^^^^^^^^^^^
      alias visit_constant_path_or_write_node visit_constant_path_operator_write_node

      # Foo::Bar, = baz
      # ^^^^^^^^
      def visit_constant_path_target_node(node)
        builder.assignable(visit_constant_path_node(node))
      end

      # def foo; end
      # ^^^^^^^^^^^^
      #
      # def self.foo; end
      # ^^^^^^^^^^^^^^^^^
      def visit_def_node(node)
        if node.equal_loc
          if node.receiver
            builder.def_endless_singleton(
              token(node.def_keyword_loc),
              visit(node.receiver.is_a?(::Prism::ParenthesesNode) ? node.receiver.body : node.receiver),
              token(node.operator_loc),
              token(node.name_loc),
              builder.args(token(node.lparen_loc), visit(node.parameters) || [], token(node.rparen_loc), false),
              token(node.equal_loc),
              with_locals(node.locals) { visit(node.body) }
            )
          else
            builder.def_endless_method(
              token(node.def_keyword_loc),
              token(node.name_loc),
              builder.args(token(node.lparen_loc), visit(node.parameters) || [], token(node.rparen_loc), false),
              token(node.equal_loc),
              with_locals(node.locals) { visit(node.body) }
            )
          end
        elsif node.receiver
          builder.def_singleton(
            token(node.def_keyword_loc),
            visit(node.receiver.is_a?(::Prism::ParenthesesNode) ? node.receiver.body : node.receiver),
            token(node.operator_loc),
            token(node.name_loc),
            builder.args(token(node.lparen_loc), visit(node.parameters) || [], token(node.rparen_loc), false),
            with_locals(node.locals) { visit(node.body) },
            token(node.end_keyword_loc)
          )
        else
          builder.def_method(
            token(node.def_keyword_loc),
            token(node.name_loc),
            builder.args(token(node.lparen_loc), visit(node.parameters) || [], token(node.rparen_loc), false),
            with_locals(node.locals) { visit(node.body) },
            token(node.end_keyword_loc)
          )
        end
      end

      # defined? a
      # ^^^^^^^^^^
      #
      # defined?(a)
      # ^^^^^^^^^^^
      def visit_defined_node(node)
        builder.keyword_cmd(
          :defined?,
          token(node.keyword_loc),
          token(node.lparen_loc),
          [visit(node.value)],
          token(node.rparen_loc)
        )
      end

      # if foo then bar else baz end
      #                 ^^^^^^^^^^^^
      def visit_else_node(node)
        visit(node.statements)
      end

      # "foo #{bar}"
      #      ^^^^^^
      def visit_embedded_statements_node(node)
        builder.begin(
          token(node.opening_loc),
          visit(node.statements),
          token(node.closing_loc)
        )
      end

      # "foo #@bar"
      #      ^^^^^
      def visit_embedded_variable_node(node)
        visit(node.variable)
      end

      # begin; foo; ensure; bar; end
      #             ^^^^^^^^^^^^
      def visit_ensure_node(node)
        raise "Cannot directly compile ensure nodes"
      end

      # false
      # ^^^^^
      def visit_false_node(node)
        builder.false(token(node.location))
      end

      # foo => [*, bar, *]
      #        ^^^^^^^^^^^
      def visit_find_pattern_node(node)
        if node.constant
          builder.const_pattern(visit(node.constant), token(node.opening_loc), builder.find_pattern(nil, visit_all([node.left, *node.requireds, node.right]), nil), token(node.closing_loc))
        else
          builder.find_pattern(token(node.opening_loc), visit_all([node.left, *node.requireds, node.right]), token(node.closing_loc))
        end
      end

      # 1.0
      # ^^^
      def visit_float_node(node)
        visit_numeric(node, builder.float([node.value, srange(node.location)]))
      end

      # for foo in bar do end
      # ^^^^^^^^^^^^^^^^^^^^^
      def visit_for_node(node)
        builder.for(
          token(node.for_keyword_loc),
          visit(node.index),
          token(node.in_keyword_loc),
          visit(node.collection),
          if node.do_keyword_loc
            token(node.do_keyword_loc)
          else
            srange_find(node.collection.location.end_offset, (node.statements&.location || node.end_keyword_loc).start_offset, [";"])
          end,
          visit(node.statements),
          token(node.end_keyword_loc)
        )
      end

      # def foo(...); bar(...); end
      #                   ^^^
      def visit_forwarding_arguments_node(node)
        builder.forwarded_args(token(node.location))
      end

      # def foo(...); end
      #         ^^^
      def visit_forwarding_parameter_node(node)
        builder.forward_arg(token(node.location))
      end

      # super
      # ^^^^^
      #
      # super {}
      # ^^^^^^^^
      def visit_forwarding_super_node(node)
        visit_block(
          builder.keyword_cmd(
            :zsuper,
            ["super", srange_offsets(node.location.start_offset, node.location.start_offset + 5)]
          ),
          node.block
        )
      end

      # $foo
      # ^^^^
      def visit_global_variable_read_node(node)
        builder.gvar(token(node.location))
      end

      # $foo = 1
      # ^^^^^^^^
      #
      # $foo, $bar = 1
      # ^^^^  ^^^^
      def visit_global_variable_write_node(node)
        builder.assign(
          builder.assignable(builder.gvar(token(node.name_loc))),
          token(node.operator_loc),
          visit(node.value)
        )
      end

      # $foo += bar
      # ^^^^^^^^^^^
      def visit_global_variable_operator_write_node(node)
        builder.op_assign(
          builder.assignable(builder.gvar(token(node.name_loc))),
          [node.operator, srange(node.operator_loc)],
          visit(node.value)
        )
      end

      # $foo &&= bar
      # ^^^^^^^^^^^^
      alias visit_global_variable_and_write_node visit_global_variable_operator_write_node

      # $foo ||= bar
      # ^^^^^^^^^^^^
      alias visit_global_variable_or_write_node visit_global_variable_operator_write_node

      # $foo, = bar
      # ^^^^
      def visit_global_variable_target_node(node)
        builder.assignable(builder.gvar([node.slice, srange(node.location)]))
      end

      # {}
      # ^^
      def visit_hash_node(node)
        builder.associate(
          token(node.opening_loc),
          visit_all(node.elements),
          token(node.closing_loc)
        )
      end

      # foo => {}
      #        ^^
      def visit_hash_pattern_node(node)
        if node.constant
          builder.const_pattern(visit(node.constant), token(node.opening_loc), builder.hash_pattern(nil, visit_all(node.assocs), nil), token(node.closing_loc))
        else
          builder.hash_pattern(token(node.opening_loc), visit_all(node.assocs), token(node.closing_loc))
        end
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
          builder.ternary(
            visit(node.predicate),
            srange_find(node.predicate.location.end_offset, node.statements.location.start_offset, ["?"]),
            visit(node.statements),
            token(node.consequent.else_keyword_loc),
            visit(node.consequent)
          )
        elsif node.if_keyword_loc.start_offset == node.location.start_offset
          builder.condition(
            token(node.if_keyword_loc),
            visit(node.predicate),
            srange_find(node.predicate.location.end_offset, (node.statements&.location || node.consequent&.location || node.end_keyword_loc).start_offset, [";", "then"]),
            visit(node.statements),
            case node.consequent
            when ::Prism::IfNode
              token(node.consequent.if_keyword_loc)
            when ::Prism::ElseNode
              token(node.consequent.else_keyword_loc)
            end,
            visit(node.consequent),
            if node.if_keyword != "elsif"
              token(node.end_keyword_loc)
            end
          )
        else
          builder.condition_mod(
            visit(node.statements),
            visit(node.consequent),
            token(node.if_keyword_loc),
            visit(node.predicate)
          )
        end
      end

      # 1i
      def visit_imaginary_node(node)
        visit_numeric(node, builder.complex([node.value, srange(node.location)]))
      end

      # { foo: }
      #   ^^^^
      def visit_implicit_node(node)
        raise "Cannot directly compile implicit nodes"
      end

      # case foo; in bar; end
      # ^^^^^^^^^^^^^^^^^^^^^
      def visit_in_node(node)
        pattern = nil
        guard = nil

        case node.pattern
        when ::Prism::IfNode
          pattern = within_pattern { visit(node.pattern.statements) }
          guard = builder.if_guard(token(node.pattern.if_keyword_loc), visit(node.pattern.predicate))
        when ::Prism::UnlessNode
          pattern = within_pattern { visit(node.pattern.statements) }
          guard = builder.unless_guard(token(node.pattern.keyword_loc), visit(node.pattern.predicate))
        else
          pattern = within_pattern { visit(node.pattern) }
        end

        builder.in_pattern(
          token(node.in_loc),
          pattern,
          guard,
          srange_find(node.pattern.location.end_offset, node.statements&.location&.start_offset || node.location.end_offset, [";", "then"]),
          visit(node.statements)
        )
      end

      # @foo
      # ^^^^
      def visit_instance_variable_read_node(node)
        builder.ivar(token(node.location))
      end

      # @foo = 1
      # ^^^^^^^^
      #
      # @foo, @bar = 1
      # ^^^^  ^^^^
      def visit_instance_variable_write_node(node)
        builder.assign(
          builder.assignable(builder.ivar(token(node.name_loc))),
          token(node.operator_loc),
          visit(node.value)
        )
      end

      # @foo += bar
      # ^^^^^^^^^^^
      def visit_instance_variable_operator_write_node(node)
        builder.op_assign(
          builder.assignable(builder.ivar(token(node.name_loc))),
          [node.operator_loc.slice.chomp("="), srange(node.operator_loc)],
          visit(node.value)
        )
      end

      # @foo &&= bar
      # ^^^^^^^^^^^^
      alias visit_instance_variable_and_write_node visit_instance_variable_operator_write_node

      # @foo ||= bar
      # ^^^^^^^^^^^^
      alias visit_instance_variable_or_write_node visit_instance_variable_operator_write_node

      # @foo, = bar
      # ^^^^
      def visit_instance_variable_target_node(node)
        builder.assignable(builder.ivar(token(node.location)))
      end

      # 1
      # ^
      def visit_integer_node(node)
        visit_numeric(node, builder.integer([node.value, srange(node.location)]))
      end

      # /foo #{bar}/
      # ^^^^^^^^^^^^
      def visit_interpolated_regular_expression_node(node)
        builder.regexp_compose(
          token(node.opening_loc),
          visit_all(node.parts),
          [node.closing[0], srange_offsets(node.closing_loc.start_offset, node.closing_loc.start_offset + 1)],
          builder.regexp_options([node.closing[1..], srange_offsets(node.closing_loc.start_offset + 1, node.closing_loc.end_offset)])
        )
      end

      # if /foo #{bar}/ then end
      #    ^^^^^^^^^^^^
      alias visit_interpolated_match_last_line_node visit_interpolated_regular_expression_node

      # "foo #{bar}"
      # ^^^^^^^^^^^^
      def visit_interpolated_string_node(node)
        if node.opening&.start_with?("<<")
          children, closing = visit_heredoc(node)
          builder.string_compose(token(node.opening_loc), children, closing)
        else
          builder.string_compose(
            token(node.opening_loc),
            visit_all(node.parts),
            token(node.closing_loc)
          )
        end
      end

      # :"foo #{bar}"
      # ^^^^^^^^^^^^^
      def visit_interpolated_symbol_node(node)
        builder.symbol_compose(
          token(node.opening_loc),
          visit_all(node.parts),
          token(node.closing_loc)
        )
      end

      # `foo #{bar}`
      # ^^^^^^^^^^^^
      def visit_interpolated_x_string_node(node)
        if node.opening.start_with?("<<")
          children, closing = visit_heredoc(node)
          builder.xstring_compose(token(node.opening_loc), children, closing)
        else
          builder.xstring_compose(
            token(node.opening_loc),
            visit_all(node.parts),
            token(node.closing_loc)
          )
        end
      end

      # foo(bar: baz)
      #     ^^^^^^^^
      def visit_keyword_hash_node(node)
        builder.associate(nil, visit_all(node.elements), nil)
      end

      # def foo(bar:); end
      #         ^^^^
      #
      # def foo(bar: baz); end
      #         ^^^^^^^^
      def visit_keyword_parameter_node(node)
        if node.value
          builder.kwoptarg([node.name, srange(node.name_loc)], visit(node.value))
        else
          builder.kwarg([node.name, srange(node.name_loc)])
        end
      end

      # def foo(**bar); end
      #         ^^^^^
      #
      # def foo(**); end
      #         ^^
      def visit_keyword_rest_parameter_node(node)
        builder.kwrestarg(
          token(node.operator_loc),
          node.name ? [node.name, srange(node.name_loc)] : nil
        )
      end

      # -> {}
      def visit_lambda_node(node)
        builder.block(
          builder.call_lambda(token(node.operator_loc)),
          [node.opening, srange(node.opening_loc)],
          if node.parameters
            builder.args(
              token(node.parameters.opening_loc),
              visit(node.parameters),
              token(node.parameters.closing_loc),
              false
            )
          else
            builder.args(nil, [], nil, false)
          end,
          with_locals(node.locals) { visit(node.body) },
          [node.closing, srange(node.closing_loc)]
        )
      end

      # foo
      # ^^^
      def visit_local_variable_read_node(node)
        builder.ident([node.name, srange(node.location)]).updated(:lvar)
      end

      # foo = 1
      # ^^^^^^^
      #
      # foo, bar = 1
      # ^^^  ^^^
      def visit_local_variable_write_node(node)
        builder.assign(
          builder.assignable(builder.ident(token(node.name_loc))),
          token(node.operator_loc),
          visit(node.value)
        )
      end

      # foo += bar
      # ^^^^^^^^^^
      def visit_local_variable_operator_write_node(node)
        builder.op_assign(
          builder.assignable(builder.ident(token(node.name_loc))),
          [node.operator_loc.slice.chomp("="), srange(node.operator_loc)],
          visit(node.value)
        )
      end

      # foo &&= bar
      # ^^^^^^^^^^^
      alias visit_local_variable_and_write_node visit_local_variable_operator_write_node

      # foo ||= bar
      # ^^^^^^^^^^^
      alias visit_local_variable_or_write_node visit_local_variable_operator_write_node

      # foo, = bar
      # ^^^
      def visit_local_variable_target_node(node)
        if context_pattern
          builder.assignable(builder.match_var([node.name, srange(node.location)]))
        else
          builder.assignable(builder.ident(token(node.location)))
        end
      end

      # foo in bar
      # ^^^^^^^^^^
      def visit_match_predicate_node(node)
        builder.match_pattern_p(
          visit(node.value),
          token(node.operator_loc),
          within_pattern { visit(node.pattern) }
        )
      end

      # foo => bar
      # ^^^^^^^^^^
      def visit_match_required_node(node)
        builder.match_pattern(
          visit(node.value),
          token(node.operator_loc),
          within_pattern { visit(node.pattern) }
        )
      end

      # /(?<foo>foo)/ =~ bar
      # ^^^^^^^^^^^^^^^^^^^^
      def visit_match_write_node(node)
        builder.match_op(
          visit(node.call.receiver),
          token(node.call.message_loc),
          visit(node.call.arguments.arguments.first)
        )
      end

      # A node that is missing from the syntax tree. This is only used in the
      # case of a syntax error. The parser gem doesn't have such a concept, so
      # we invent our own here.
      def visit_missing_node(node)
        raise "Cannot compile missing nodes"
      end

      # module Foo; end
      # ^^^^^^^^^^^^^^^
      def visit_module_node(node)
        builder.def_module(
          token(node.module_keyword_loc),
          visit(node.constant_path),
          with_locals(node.locals) { visit(node.body) },
          token(node.end_keyword_loc)
        )
      end

      # foo, bar = baz
      # ^^^^^^^^
      def visit_multi_target_node(node)
        if node.targets.length == 1 || (node.targets.length == 2 && node.targets.last.is_a?(::Prism::SplatNode) && node.targets.last.operator == ",")
          visit(node.targets.first)
        else
          builder.multi_lhs(
            token(node.lparen_loc),
            visit_all(node.targets),
            token(node.rparen_loc)
          )
        end
      end

      # foo, bar = baz
      # ^^^^^^^^^^^^^^
      def visit_multi_write_node(node)
        builder.multi_assign(
          builder.multi_lhs(
            token(node.lparen_loc),
            visit_all(node.targets),
            token(node.rparen_loc)
          ),
          token(node.operator_loc),
          visit(node.value)
        )
      end

      # next
      # ^^^^
      #
      # next foo
      # ^^^^^^^^
      def visit_next_node(node)
        builder.keyword_cmd(
          :next,
          token(node.keyword_loc),
          nil,
          visit(node.arguments) || [],
          nil
        )
      end

      # nil
      # ^^^
      def visit_nil_node(node)
        builder.nil(token(node.location))
      end

      # def foo(**nil); end
      #         ^^^^^
      def visit_no_keywords_parameter_node(node)
        builder.kwnilarg(token(node.operator_loc), token(node.keyword_loc))
      end

      # $1
      # ^^
      def visit_numbered_reference_read_node(node)
        builder.nth_ref([node.number, srange(node.location)])
      end

      # def foo(bar = 1); end
      #         ^^^^^^^
      def visit_optional_parameter_node(node)
        builder.optarg(token(node.name_loc), token(node.operator_loc), visit(node.value))
      end

      # a or b
      # ^^^^^^
      def visit_or_node(node)
        builder.logical_op(:or, visit(node.left), token(node.operator_loc), visit(node.right))
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
        builder.begin(
          token(node.opening_loc),
          visit(node.body),
          token(node.closing_loc)
        )
      end

      # foo => ^(bar)
      #        ^^^^^^
      def visit_pinned_expression_node(node)
        builder.pin(token(node.operator_loc), visit(node.expression))
      end

      # foo = 1 and bar => ^foo
      #                    ^^^^
      def visit_pinned_variable_node(node)
        builder.pin(token(node.operator_loc), visit(node.variable))
      end

      # END {}
      def visit_post_execution_node(node)
        builder.postexe(
          token(node.keyword_loc),
          token(node.opening_loc),
          visit(node.statements),
          token(node.closing_loc)
        )
      end

      # BEGIN {}
      def visit_pre_execution_node(node)
        builder.preexe(
          token(node.keyword_loc),
          token(node.opening_loc),
          visit(node.statements),
          token(node.closing_loc)
        )
      end

      # The top-level program node.
      def visit_program_node(node)
        with_locals(node.locals) { builder.compstmt(visit_all(node.statements.body)) }
      end

      # 0..5
      # ^^^^
      def visit_range_node(node)
        if node.exclude_end?
          builder.range_exclusive(
            visit(node.left),
            token(node.operator_loc),
            visit(node.right)
          )
        else
          builder.range_inclusive(
            visit(node.left),
            token(node.operator_loc),
            visit(node.right)
          )
        end
      end

      # if foo .. bar; end
      #    ^^^^^^^^^^
      alias visit_flip_flop_node visit_range_node

      # 1r
      # ^^
      def visit_rational_node(node)
        visit_numeric(node, builder.rational([node.value, srange(node.location)]))
      end

      # redo
      # ^^^^
      def visit_redo_node(node)
        builder.keyword_cmd(:redo, token(node.location))
      end

      # /foo/
      # ^^^^^
      def visit_regular_expression_node(node)
        builder.regexp_compose(
          token(node.opening_loc),
          [builder.string_internal(token(node.content_loc))],
          [node.closing[0], srange_offsets(node.closing_loc.start_offset, node.closing_loc.start_offset + 1)],
          builder.regexp_options([node.closing[1..], srange_offsets(node.closing_loc.start_offset + 1, node.closing_loc.end_offset)])
        )
      end

      # if /foo/ then end
      #    ^^^^^
      alias visit_match_last_line_node visit_regular_expression_node

      # def foo((bar)); end
      #         ^^^^^
      def visit_required_destructured_parameter_node(node)
        builder.multi_lhs(
          token(node.opening_loc),
          within_destructure { visit_all(node.parameters) },
          token(node.closing_loc)
        )
      end

      # def foo(bar); end
      #         ^^^
      def visit_required_parameter_node(node)
        builder.arg(token(node.location))
      end

      # foo rescue bar
      # ^^^^^^^^^^^^^^
      def visit_rescue_modifier_node(node)
        builder.begin_body(
          visit(node.expression),
          [
            builder.rescue_body(
              token(node.keyword_loc),
              nil,
              nil,
              nil,
              nil,
              visit(node.rescue_expression)
            )
          ]
        )
      end

      # begin; rescue; end
      #        ^^^^^^^
      def visit_rescue_node(node)
        raise "Cannot directly compile rescue nodes"
      end

      # def foo(*bar); end
      #         ^^^^
      #
      # def foo(*); end
      #         ^
      def visit_rest_parameter_node(node)
        builder.restarg(token(node.operator_loc), token(node.name_loc))
      end

      # retry
      # ^^^^^
      def visit_retry_node(node)
        builder.keyword_cmd(:retry, token(node.location))
      end

      # return
      # ^^^^^^
      #
      # return 1
      # ^^^^^^^^
      def visit_return_node(node)
        builder.keyword_cmd(
          :return,
          token(node.keyword_loc),
          nil,
          visit(node.arguments) || [],
          nil
        )
      end

      # self
      # ^^^^
      def visit_self_node(node)
        builder.self(token(node.location))
      end

      # class << self; end
      # ^^^^^^^^^^^^^^^^^^
      def visit_singleton_class_node(node)
        builder.def_sclass(
          token(node.class_keyword_loc),
          token(node.operator_loc),
          visit(node.expression),
          with_locals(node.locals) { visit(node.body) },
          token(node.end_keyword_loc)
        )
      end

      # __ENCODING__
      # ^^^^^^^^^^^^
      def visit_source_encoding_node(node)
        builder.accessible(builder.__ENCODING__(token(node.location)))
      end

      # __FILE__
      # ^^^^^^^^
      def visit_source_file_node(node)
        builder.accessible(builder.__FILE__(token(node.location)))
      end

      # __LINE__
      # ^^^^^^^^
      def visit_source_line_node(node)
        builder.accessible(builder.__LINE__(token(node.location)))
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
        if node.expression.nil? && context_locals.include?(:*)
          builder.forwarded_restarg(token(node.operator_loc))
        elsif context_destructure
          builder.restarg(token(node.operator_loc), token(node.expression&.location))
        elsif context_pattern
          builder.match_rest(token(node.operator_loc), token(node.expression&.location))
        else
          builder.splat(token(node.operator_loc), visit(node.expression))
        end
      end

      # A list of statements.
      def visit_statements_node(node)
        builder.compstmt(visit_all(node.body))
      end

      # "foo" "bar"
      # ^^^^^^^^^^^
      def visit_string_concat_node(node)
        builder.word([visit(node.left), visit(node.right)])
      end

      # "foo"
      # ^^^^^
      def visit_string_node(node)
        if node.opening&.start_with?("<<")
          children, closing = visit_heredoc(::Prism::InterpolatedStringNode.new(node.opening_loc, [node.copy(opening_loc: nil, closing_loc: nil, location: node.content_loc)], node.closing_loc, node.location))
          builder.string_compose(token(node.opening_loc), children, closing)
        elsif node.opening == "?"
          builder.character([node.unescaped, srange(node.location)])
        else
          builder.string_compose(
            token(node.opening_loc),
            [builder.string_internal([node.unescaped, srange(node.content_loc)])],
            token(node.closing_loc)
          )
        end
      end

      # super(foo)
      # ^^^^^^^^^^
      def visit_super_node(node)
        arguments = node.arguments&.arguments || []
        block = node.block

        if block.is_a?(::Prism::BlockArgumentNode)
          arguments = [*arguments, block]
          block = nil
        end

        visit_block(
          builder.keyword_cmd(
            :super,
            token(node.keyword_loc),
            token(node.lparen_loc),
            visit_all(arguments),
            token(node.rparen_loc)
          ),
          block
        )
      end

      # :foo
      # ^^^^
      def visit_symbol_node(node)
        if node.closing_loc.nil?
          if node.opening_loc.nil?
            builder.symbol_internal([node.unescaped, srange(node.location)])
          else
            builder.symbol([node.unescaped, srange(node.location)])
          end
        else
          builder.symbol_compose(
            token(node.opening_loc),
            [builder.string_internal([node.unescaped, srange(node.value_loc)])],
            token(node.closing_loc)
          )
        end
      end

      # true
      # ^^^^
      def visit_true_node(node)
        builder.true(token(node.location))
      end

      # undef foo
      # ^^^^^^^^^
      def visit_undef_node(node)
        builder.undef_method(token(node.keyword_loc), visit_all(node.names))
      end

      # unless foo; bar end
      # ^^^^^^^^^^^^^^^^^^^
      #
      # bar unless foo
      # ^^^^^^^^^^^^^^
      def visit_unless_node(node)
        if node.keyword_loc.start_offset == node.location.start_offset
          builder.condition(
            token(node.keyword_loc),
            visit(node.predicate),
            srange_find(node.predicate.location.end_offset, (node.statements&.location || node.consequent&.location || node.end_keyword_loc).start_offset, [";", "then"]),
            visit(node.consequent),
            token(node.consequent&.else_keyword_loc),
            visit(node.statements),
            token(node.end_keyword_loc)
          )
        else
          builder.condition_mod(
            visit(node.consequent),
            visit(node.statements),
            token(node.keyword_loc),
            visit(node.predicate)
          )
        end
      end

      # until foo; bar end
      # ^^^^^^^^^^^^^^^^^
      #
      # bar until foo
      # ^^^^^^^^^^^^^
      def visit_until_node(node)
        if node.location.start_offset == node.keyword_loc.start_offset
          builder.loop(
            :until,
            token(node.keyword_loc),
            visit(node.predicate),
            srange_find(node.predicate.location.end_offset, (node.statements&.location || node.closing_loc).start_offset, [";", "do"]),
            visit(node.statements),
            token(node.closing_loc)
          )
        else
          builder.loop_mod(
            :until,
            visit(node.statements),
            token(node.keyword_loc),
            visit(node.predicate)
          )
        end
      end

      # case foo; when bar; end
      #           ^^^^^^^^^^^^^
      def visit_when_node(node)
        builder.when(
          token(node.keyword_loc),
          visit_all(node.conditions),
          srange_find(node.conditions.last.location.end_offset, node.statements&.location&.start_offset || (node.conditions.last.location.end_offset + 1), [";", "then"]),
          visit(node.statements)
        )
      end

      # while foo; bar end
      # ^^^^^^^^^^^^^^^^^^
      #
      # bar while foo
      # ^^^^^^^^^^^^^
      def visit_while_node(node)
        if node.location.start_offset == node.keyword_loc.start_offset
          builder.loop(
            :while,
            token(node.keyword_loc),
            visit(node.predicate),
            srange_find(node.predicate.location.end_offset, (node.statements&.location || node.closing_loc).start_offset, [";", "do"]),
            visit(node.statements),
            token(node.closing_loc)
          )
        else
          builder.loop_mod(
            :while,
            visit(node.statements),
            token(node.keyword_loc),
            visit(node.predicate)
          )
        end
      end

      # `foo`
      # ^^^^^
      def visit_x_string_node(node)
        if node.opening&.start_with?("<<")
          children, closing = visit_heredoc(::Prism::InterpolatedXStringNode.new(node.opening_loc, [::Prism::StringNode.new(0, nil, node.content_loc, nil, node.unescaped, node.content_loc)], node.closing_loc, node.location))
          builder.xstring_compose(token(node.opening_loc), children, closing)
        else
          builder.xstring_compose(
            token(node.opening_loc),
            [builder.string_internal([node.unescaped, srange(node.content_loc)])],
            token(node.closing_loc)
          )
        end
      end

      # yield
      # ^^^^^
      #
      # yield 1
      # ^^^^^^^
      def visit_yield_node(node)
        builder.keyword_cmd(
          :yield,
          token(node.keyword_loc),
          token(node.lparen_loc),
          visit(node.arguments) || [],
          token(node.rparen_loc)
        )
      end

      private

      # Blocks can have a special set of parameters that automatically expand
      # when given arrays if they have a single required parameter and no other
      # parameters.
      def procarg0?(parameters)
        parameters &&
          parameters.requireds.length == 1 &&
          parameters.optionals.empty? &&
          parameters.rest.nil? &&
          parameters.posts.empty? &&
          parameters.keywords.empty? &&
          parameters.keyword_rest.nil? &&
          parameters.block.nil?
      end

      # Constructs a new source range from the given start and end offsets.
      def srange(location)
        Source::Range.new(source_buffer, location.start_offset, location.end_offset) if location
      end

      # Constructs a new source range from the given start and end offsets.
      def srange_offsets(start_offset, end_offset)
        Source::Range.new(source_buffer, start_offset, end_offset)
      end

      # Constructs a new source range by finding the given tokens between the
      # given start offset and end offset. If the needle is not found, it
      # returns nil.
      def srange_find(start_offset, end_offset, tokens)
        tokens.find do |token|
          next unless (index = source_buffer.source.byteslice(start_offset...end_offset).index(token))
          offset = start_offset + index
          return [token, Source::Range.new(source_buffer, offset, offset + token.length)]
        end
      end

      # Transform a location into a token that the parser gem expects.
      def token(location)
        [location.slice, Source::Range.new(source_buffer, location.start_offset, location.end_offset)] if location
      end

      # Visit a block node on a call.
      def visit_block(call, block)
        if block
          builder.block(
            call,
            [block.opening, srange(block.opening_loc)],
            builder.args(
              token(block.parameters&.opening_loc),
              if block.parameters.nil?
                []
              elsif procarg0?(block.parameters.parameters)
                parameter = block.parameters.parameters.requireds.first
                [builder.procarg0(visit(parameter))].concat(visit_all(block.parameters.locals))
              else
                visit(block.parameters)
              end,
              token(block.parameters&.closing_loc),
              false
            ),
            visit(block.body),
            [block.closing, srange(block.closing_loc)]
          )
        else
          call
        end
      end

      # Visit a heredoc that can be either a string or an xstring.
      def visit_heredoc(node)
        children = []
        node.parts.each do |part|
          pushing =
            if part.is_a?(::Prism::StringNode) && part.unescaped.count("\n") > 1
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
                end_offset = start_offset + (escaped_length || 0)
                inner_part = builder.string_internal(["#{unescaped_line}\n", srange_offsets(start_offset, end_offset)])

                start_offset = end_offset
                inner_part
              end
            else
              [visit(part)]
            end

          pushing.each do |child|
            if child.type == :str && child.children.last == ""
              # nothing
            elsif child.type == :str && children.last && children.last.type == :str && !children.last.children.first.end_with?("\n")
              children.last.children.first << child.children.first
            else
              children << child
            end
          end
        end

        closing = node.closing
        closing_t = [closing.chomp, srange_offsets(node.closing_loc.start_offset, node.closing_loc.end_offset - closing[/\s+$/].length)]

        [children, closing_t]
      end

      # Visit a numeric node and account for the optional sign.
      def visit_numeric(node, value)
        if (slice = node.slice).match?(/^[+-]/)
          builder.unary_num(
            [slice[0].to_sym, srange_offsets(node.location.start_offset, node.location.start_offset + 1)],
            value
          )
        else
          value
        end
      end

      # Within the given block, use the given set of context_locals.
      def with_locals(locals)
        previous = @context_locals
        @context_locals = locals

        begin
          yield
        ensure
          @context_locals = previous
        end
      end

      # Within the given block, track that we're within a destructure.
      def within_destructure
        previous = @context_destructure
        @context_destructure = true

        begin
          yield
        ensure
          @context_destructure = previous
        end
      end

      # Within the given block, track that we're within a pattern.
      def within_pattern
        previous = @context_pattern
        @context_pattern = true

        begin
          parser.pattern_variables.push
          yield
        ensure
          @context_pattern = previous
          parser.pattern_variables.pop
        end
      end
    end
  end
end

# Validate that the visitor has a visit method for each node type and only those
# node types.
expected = Prism.constants.grep(/.Node$/).map(&:name)
actual =
  Parser::Prism::Compiler.instance_methods(false).grep(/^visit_/).map do
    _1[6..].split("_").map(&:capitalize).join
  end

if (extra = actual - expected).any?
  raise "Unexpected visit methods for: #{extra.join(", ")}"
end

if (missing = expected - actual).any?
  raise "Missing visit methods for: #{missing.join(", ")}"
end
