# frozen_string_literal: true

require "parser"
require "rubocop"

module Parser
  class Prism < Base
    VERSION_3_3 = 89_65_82_80.33
  end
end

RuboCop::AST::ProcessedSource.prepend(
  Module.new do
    def parser_class(ruby_version)
      if ruby_version == Parser::Prism::VERSION_3_3
        require "parser/prism"
        Parser::Prism
      else
        super
      end
    end
  end
)

known_rubies = RuboCop::TargetRuby.const_get(:KNOWN_RUBIES)
RuboCop::TargetRuby.send(:remove_const, :KNOWN_RUBIES)
RuboCop::TargetRuby::KNOWN_RUBIES = [*known_rubies, Parser::Prism::VERSION_3_3].freeze
