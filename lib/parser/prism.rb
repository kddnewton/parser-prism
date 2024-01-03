# frozen_string_literal: true

require "parser"
require "prism"

module Parser
  class Prism < Base
    Racc_debug_parser = false

    def version
      33
    end

    def default_encoding
      Encoding::UTF_8
    end

    def yyerror
    end

    ##
    # Parses a source buffer and returns the AST.
    #
    # @param [Parser::Source::Buffer] source_buffer The source buffer to parse.
    # @return Parser::AST::Node
    #
    def parse(source_buffer)
      @source_buffer = source_buffer
      source = source_buffer.source

      build_ast(
        ::Prism.parse(source, filepath: source_buffer.name).value,
        build_offset_cache(source)
      )
    ensure
      @source_buffer = nil
    end

    ##
    # Parses a source buffer and returns the AST and the source code comments.
    #
    # @see #parse
    # @see Parser::Source::Comment#associate
    # @return [Array]
    #
    def parse_with_comments(source_buffer)
      @source_buffer = source_buffer
      source = source_buffer.source

      result = ::Prism.parse(source, filepath: source_buffer.name)

      [
        build_ast(result.value, build_offset_cache(source)),
        build_comments(result.comments)
      ]
    ensure
      @source_buffer = nil
    end

    ##
    # Parses a source buffer and returns the AST, the source code comments,
    # and the tokens emitted by the lexer.
    #
    # @param [Parser::Source::Buffer] source_buffer
    # @return [Array]
    #
    def tokenize(source_buffer, _recover = false)
      @source_buffer = source_buffer
      source = source_buffer.source

      offset_cache = build_offset_cache(source)
      result = ::Prism.parse_lex(source, filepath: source_buffer.name)
      program, tokens = result.value

      [
        build_ast(program, offset_cache),
        build_comments(result.comments),
        build_tokens(tokens, offset_cache)
      ]
    ensure
      @source_buffer = nil
    end

    # Since prism resolves num params for us, we don't need to support this kind
    # of logic here.
    def try_declare_numparam(node)
      node.children[0].match?(/\A_[1-9]\z/)
    end

    private

    # Prism deals with offsets in bytes, while the parser gem deals with offsets
    # in characters. We need to handle this conversion in order to build the
    # parser gem AST.
    #
    # If the bytesize of the source is the same as the length, then we can just
    # use the offset directly. Otherwise, we build a hash that functions as a
    # cache for the conversion.
    def build_offset_cache(source)
      if source.bytesize == source.length
        -> (offset) { offset }
      else
        Hash.new { |hash, offset| hash[offset] = source.byteslice(0, offset).length }
      end
    end

    # Build the parser gem AST from the prism AST.
    def build_ast(program, offset_cache)
      program.accept(Compiler.new(self, offset_cache))
    end

    # Build the parser gem comments from the prism comments.
    def build_comments(comments)
      comments.map do |comment|
        location = comment.location
        Source::Comment.new(Source::Range.new(source_buffer, location.start_offset, location.end_offset))
      end
    end

    # Build the parser gem tokens from the prism tokens.
    def build_tokens(tokens, offset_cache)
      Lexer.new(source_buffer, tokens.map(&:first), offset_cache).to_a
    end
  end
end

require_relative "prism/compiler"
require_relative "prism/lexer"
