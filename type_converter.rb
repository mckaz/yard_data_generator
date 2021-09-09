## Converts YARD types to a standardized format.
## This code is lifted from the Yard Types Parser by lsegal: https://github.com/lsegal/yard-types-parser
## Minor changes have been applied.
require 'strscan'

SINGLE_ARG_GENERIC_TYPES = %w{Array Set Enumerable Enumerator Range}
=begin
class Array
  def list_join
    index = 0
    inject("") do |acc, el|
      acc << el.to_s
      #acc << ", " if index < size - 2
      acc << " or " #if index == size - 2
      index += 1
      acc
    end
  end
end
=end

module YARDTC
  class Type
    attr_accessor :name
    
    def initialize(name)
      name = "Boolean" if ["true or false", "bool", "Bool", "boolean", "Boolean", "true", "false", "TrueClass", "FalseClass", "TrueClass or FalseClass"].include?(name)
      name = "Integer" if ["Fixnum", "int", "Bignum", "Int"].include?(name)
      name = name[2..-1] if name.start_with?("::")
      @name = name
    end
    
    def to_s
      name
=begin
       if name[0] == "#"
         singular ? "an object that responds to #{name}" : "objects that respond to #{name}"
       elsif name[0] =~ /[A-Z]/
         singular ? "a#{name[0] =~ /[aeiou]/i ? 'n' : ''} " + name : "#{name}#{name[-1] =~ /[A-Z]/ ? "'" : ''}s"
       else
         name
       end
=end
    end
  end

  class CollectionType < Type
    attr_accessor :types
    
    def initialize(name, types)
      @name = name
      @types = types
    end
    
    def to_s
      if SINGLE_ARG_GENERIC_TYPES.include?(name)
        "#{name}<#{types.join(' or ')}>"
      else
        "#{name}<#{types.join(', ')}>"
      end
      #"a#{name[0] =~ /[aeiou]/i ? 'n' : ''} #{name} of (" + types.map {|t| t.to_s(false) }.list_join + ")"
    end
  end

  class FixedCollectionType < CollectionType
    def to_s
      "[#{types.join(', ')}]"
      #"a#{name[0] =~ /[aeiou]/i ? 'n' : ''} #{name} containing (" + types.map(&:to_s).join(" followed by ") + ")"
    end
  end

  class HashCollectionType < Type
    attr_accessor :key_types, :value_types
    
    def initialize(name, key_types, value_types)
      @name = name
      @key_types = key_types
      @value_types = value_types
    end
    
    def to_s
      "Hash<#{key_types.join(' or ')}, #{value_types.join(' or ')}>"
      #"a#{name[0] =~ /[aeiou]/i ? 'n' : ''} #{name} with keys made of (" + key_types.map {|t| t.to_s(false) }.list_join + 
      #  ") and values of (" + value_types.map {|t| t.to_s(false) }.list_join + ")"
    end
  end

  class Parser
    TOKENS = {
      collection_start: /</,
      collection_end: />/,
      fixed_collection_start: /\(/,
      fixed_collection_end: /\)/,
      type_name: /#\w+|((::)?\w+)+/,
      type_next: /[,;]/,
      whitespace: /\s+/,
      hash_collection_start: /\{/,
      hash_collection_next: /=>/,
      hash_collection_end: /\}/,
      parse_end: nil
    }
    
    def self.parse(array_or_string)
      case array_or_string
      when String
        res = new(array_or_string).parse
        raise "Got multiple types back. Result: #{res}. Given String: #{array_or_string}." if res.size > 1
        res[0].to_s
      when Array
        results = []
        array_or_string.each { |t|
          raise "Expected string, got #{t} of class #{t.class}" unless t.is_a?(String)
          res = new(t).parse
          raise "Got multiple types back. Result: #{res}. Given String: #{array_or_string}." if res.size > 1
          results << res[0].to_s
        }
        return results.join(' or ')
      else
        raise "Expected Array or String, got #{array_or_string} of class #{array_or_string.class}."
      end
        
    end
    
    def initialize(string)
      @scanner = StringScanner.new(string)
    end
    
    def parse
      types = []
      type = nil
      fixed = false
      name = nil
      loop do
        found = false
        TOKENS.each do |token_type, match|
          if (match.nil? && @scanner.eos?) || (match && token = @scanner.scan(match))
            found = true
            case token_type
            when :type_name
              raise SyntaxError, "expecting END, got name '#{token}'" if name
              name = token
            when :type_next
              raise SyntaxError, "expecting name, got '#{token}' at #{@scanner.pos}" if name.nil?
              unless type
                type = Type.new(name)
              end
              types << type
              type = nil
              name = nil
            when :fixed_collection_start, :collection_start
              name ||= "Array"
              klass = token_type == :collection_start ? CollectionType : FixedCollectionType
              type = klass.new(name, parse)
            when :hash_collection_start
              name ||= "Hash"
              type = HashCollectionType.new(name, parse, parse)
            when :hash_collection_next, :hash_collection_end, :fixed_collection_end, :collection_end, :parse_end
              raise SyntaxError, "expecting name, got '#{token}'" if name.nil?
              unless type
                type = Type.new(name)
              end
              types << type 
              return types
            end
          end
        end
        raise SyntaxError, "invalid character at #{@scanner.peek(1)}" unless found
      end
    end
  end
end
=begin
## Converts YARD types to a standardized format.
## This code is largely lifted from Sord, a YARD-to-Sorbet type converted.
## Original code here: https://github.com/AaronC81/sord/blob/master/lib/sord/type_converter.rb
require 'yaml'

module TypeConverter
  # A regular expression which matches Ruby namespaces and identifiers. 
  # "Foo", "Foo::Bar", and "::Foo::Bar" are all matches, whereas "Foo.Bar"
  # or "Foo#bar" are not.
  SIMPLE_TYPE_REGEX =
    /(?:\:\:)?[a-zA-Z_][\w]*(?:\:\:[a-zA-Z_][\w]*)*/

  # A regular expression which matches a Ruby namespace immediately followed
  # by another Ruby namespace in angle brackets or curly braces.
  # This is the format usually used in YARD to model generic
  # types, such as "Array<String>", "Hash<String, Symbol>",
  # "Hash{String => Symbol}", etc.
  GENERIC_TYPE_REGEX =
    /(#{SIMPLE_TYPE_REGEX})\s*[<{]\s*(.*)\s*[>}]/
  
  # Match duck types which require the object implement one or more methods,
  # like '#foo', '#foo & #bar', '#foo&#bar&#baz', and '#foo&#bar&#baz&#foo_bar'.
  DUCK_TYPE_REGEX =
    /^\#[a-zA-Z_][\w]*(?:[a-zA-Z_][\w=]*)*(?:( ?\& ?\#)*[a-zA-Z_][\w=]*)*$/
  
  # A regular expression which matches ordered lists in the format of
  # either "Array(String, Symbol)" or "(String, Symbol)".
  ORDERED_LIST_REGEX = /^(?:Array|)\((.*)\s*\)$/

  # A regular expression which matches the shorthand Hash syntax, 
  # "{String => Symbol}".
  SHORTHAND_HASH_SYNTAX = /^{\s*(.*)\s*}$/

  # A regular expression which matches the shorthand Array syntax, 
  # "<String>".
  SHORTHAND_ARRAY_SYNTAX = /^<\s*(.*)\s*>$/

  # An array of built-in generic types supported by Sorbet.
  SUPPORTED_GENERIC_TYPES = %w{Array Set Enumerable Enumerator Range Hash Class}
  SINGLE_ARG_GENERIC_TYPES = %w{Array Set Enumerable Enumerator Range}

  # Given a string of YARD type parameters (without angle brackets), splits
  # the string into an array of each type parameter.
  # @param [String] params The type parameters.
  # @return [Array<String>] The split type parameters.
  def self.split_type_parameters(params)
    result = []
    buffer = ""
    current_bracketing_level = 0
    character_pointer = 0
    
    while character_pointer < params.length
      should_buffer = true

      current_bracketing_level += 1 if ['<', '{', '('].include?(params[character_pointer])
      # Decrease bracketing level by 1 when encountering `>` or `}`, unless
      # the previous character is `=` (to prevent hash rockets from causing
      # nesting problems).
      current_bracketing_level -= 1 if ['>', '}', ')'].include?(params[character_pointer]) && params[character_pointer - 1] != '='

      # Handle commas as separators.
      # e.g. Hash<Symbol, String>
      if params[character_pointer] == ','
        if current_bracketing_level == 0
          result << buffer.strip
          buffer = ""
          should_buffer = false
        end
      end

      # Handle hash rockets as separators.
      # e.g. Hash<Symbol => String>
      if params[character_pointer] == '=' && params[character_pointer + 1] == '>'
        if current_bracketing_level == 0
          character_pointer += 1
          result << buffer.strip
          buffer = ""
          should_buffer = false
        end
      end

      buffer += params[character_pointer] if should_buffer
      character_pointer += 1
    end

    result << buffer.strip

    result
  end

  # Converts a YARD type into a Sorbet type.
  # @param [Boolean, Array, String] yard The YARD type.
  # @param [YARD::CodeObjects::Base] item The CodeObject which the YARD type
  #   is associated with. This is used for logging and can be nil, but this
  #   will lead to less informative log messages.
  # @param [Boolean] replace_errors_with_untyped If true, T.untyped is used
  #   instead of SORD_ERROR_ constants for unknown types.
  # @param [Boolean] replace_unresolved_with_untyped If true, T.untyped is used
  #   when Sord is unable to resolve a constant.
  # @return [String]
  def self.convert_type(yard, item = nil, replace_errors_with_untyped = false, replace_unresolved_with_untyped = false)
    case yard
    when nil # Type not specified
      ""
    when "nil"
      "nil"
    when  "bool", "Bool", "boolean", "Boolean", "true", "false"
      "Boolean"
    when 'self'
      "self"
    when Array
      # If there's only one element, unwrap it, otherwise allow for a
      # selection of any of the types
      types = yard
              .map { |x| convert_type(x, item, replace_errors_with_untyped, replace_unresolved_with_untyped) }
              .uniq
      result = types.length == 1 ? convert_type(types.first) : types.map { |t| convert_type(t) }.join(" or ")
      result
    when /^#{SIMPLE_TYPE_REGEX}$/
      if SINGLE_ARG_GENERIC_TYPES.include?(yard) || (yard == "Hash")
        return yard
      end
      # If this doesn't begin with an uppercase letter, warn
      if /^[_a-z]/ === yard
        ## TODO: do we want to include these?
        #Logging.warn("#{yard} is probably not a type, but using anyway", item)
      end
      
      yard
    when DUCK_TYPE_REGEX
      yard
    when /^#{GENERIC_TYPE_REGEX}$/
      generic_type = $1
      type_parameters = $2

      if SUPPORTED_GENERIC_TYPES.include?(generic_type)
        parameters = split_type_parameters(type_parameters)
                     .map { |x| convert_type(x, item, replace_errors_with_untyped, replace_unresolved_with_untyped) }
        if SINGLE_ARG_GENERIC_TYPES.include?(generic_type) && parameters.length > 1
          "#{generic_type}<#{parameters.join(' or ')}>"
        elsif generic_type == 'Class' && parameters.length == 1
          "#{generic_type}<#{parameters[0]}>"
        #"T.class_of(#{parameters.first})"
        elsif generic_type == 'Hash'
          if parameters.length == 2
            "Hash<#{parameters.join(', ')}>"
          else
            handle_sord_error(parameters.join, "Invalid hash, must have exactly two types: #{yard.inspect}.", item, replace_errors_with_untyped)
          end
        else
          "#{generic_type}<#{parameters.join(', ')}>"
        end
      else
        return handle_sord_error(
                 generic_type,
                 "unsupported generic type #{generic_type.inspect} in #{yard.inspect}",
                 item,
                 replace_errors_with_untyped
               )
      end
    # Converts ordered lists like Array(Symbol, String) or (Symbol, String)
    # into Sorbet Tuples like [Symbol, String].
    when ORDERED_LIST_REGEX
      type_parameters = $1
      parameters = split_type_parameters(type_parameters)
                   .map { |x| convert_type(x, item, replace_errors_with_untyped, replace_unresolved_with_untyped) }
      "[#{parameters.join(', ')}]"
    when SHORTHAND_HASH_SYNTAX
      type_parameters = $1
      parameters = split_type_parameters(type_parameters)
                   .map { |x| convert_type(x, item, replace_errors_with_untyped, replace_unresolved_with_untyped) }
      # Return a warning about an invalid hash when it has more or less than two elements.
      if parameters.length == 2
        "Hash<#{parameters.join(', ')}>"
      else
        handle_sord_error(parameters.join, "Invalid hash, must have exactly two types: #{yard.inspect}.", item, replace_errors_with_untyped)
      end
    when SHORTHAND_ARRAY_SYNTAX
      type_parameters = $1
      parameters = split_type_parameters(type_parameters)
                   .map { |x| convert_type(x, item, replace_errors_with_untyped, replace_unresolved_with_untyped) }
      parameters.one? \
      ? "Array<#{parameters.first}>"
      : "Array<#{parameters.join(' or ')}>"
    else
      # Check for literals
      from_yaml = YAML.load(yard) rescue nil
      return from_yaml.class.to_s \
                               if [Symbol, Float, Integer].include?(from_yaml.class)

                                 return handle_sord_error(yard.to_s, "#{yard.inspect} does not appear to be a type", item, replace_errors_with_untyped)
                               end
    end

    # Handles SORD_ERRORs.
    #
    # @param [String] name
    # @param [String] log_warning
    # @param [YARD::CodeObjects::Base] item
    # @param [Boolean] replace_errors_with_untyped
    # @return [String]
    def self.handle_sord_error(name, log_warning, item, replace_errors_with_untyped)
      #Logging.warn(log_warning, item)
      return replace_errors_with_untyped ? "" : "PARSE_ERROR_#{name.gsub(/[^0-9A-Za-z_]/i, '')}"
    end
  end

=end
