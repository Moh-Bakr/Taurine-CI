# frozen_string_literal: true

require 'strscan'

# A conservative subset of Actions expressions: literals, context property/index access,
# allow-listed calls with checked arity, grouping, !, comparisons, && and ||.
# Unsupported or malformed syntax fails closed; see docs/cache-expression-policy.md.
# Only exact, unparenthesised top-level conjuncts count as guards. Nothing is evaluated
# or deleted: a string's doubled quotes, parentheses and operators remain opaque tokens.
module CacheExpression
  class Invalid < StandardError; end
  Node = Struct.new(:kind, :first, :last, :children)
  Token = Struct.new(:kind, :first, :last)
  CONTEXTS = %w[github needs vars strategy matrix steps inputs job runner env].freeze
  FUNCTIONS = {
    'always' => 0..0, 'cancelled' => 0..0, 'failure' => 0..0, 'success' => 0..0,
    'contains' => 2..2, 'endswith' => 2..2, 'startswith' => 2..2,
    'format' => 1..255, 'join' => 1..2, 'tojson' => 1..1, 'fromjson' => 1..1,
    'hashfiles' => 1..255
  }.freeze
  PRECEDENCE = { '||' => 1, '&&' => 2, '==' => 3, '!=' => 3,
                 '<' => 4, '<=' => 4, '>' => 4, '>=' => 4 }.freeze

  def self.top_terms(value)
    return nil unless value.is_a?(String) && value.bytesize <= 8192 && !value.match?(/[\r\n]/)

    # TemplateReader segments the original scalar BEFORE expression parsing. Padding or
    # mixed interpolation is a formatted string, so trimming could invent a guard. The
    # supported template form is exactly one whole-scalar wrapper, without literal padding.
    text = value
    if text.include?('${{')
      return nil unless text.start_with?('${{') && text.end_with?('}}')

      text = text[3...-2]
      return nil if text.include?('${{') # Nested markers, even in strings, are unsupported.
    end
    parser = Parser.new(text)
    root = parser.parse
    return nil if root.kind == '||'

    terms = lambda do |node|
      node.kind == '&&' ? node.children.flat_map { |child| terms.call(child) } : [text.byteslice(node.first...node.last)]
    end
    terms.call(root)
  rescue Invalid
    nil
  end

  class Parser
    def initialize(text)
      @text = text
      @tokens = []
      scan = StringScanner.new(text)
      until scan.eos?
        next if scan.scan(/\s+/)

        first = scan.pos
        kind = if scan.scan(/'(?:[^']|'')*'/)
                 :literal
               elsif scan.scan(/(?:0[xX][0-9a-fA-F]+|-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)/)
                 :literal
               elsif scan.scan(/[A-Za-z_][A-Za-z0-9_-]*/)
                 %w[true false null].include?(scan.matched.downcase) ? :literal : :name
               elsif scan.scan(/&&|\|\||==|!=|<=|>=|[!<>()\[\].,]/)
                 scan.matched
               else
                 raise Invalid
               end
        @tokens << Token.new(kind, first, scan.pos)
        raise Invalid if @tokens.size > 1024
      end
      @index = 0
    end

    def parse
      node = expression(1, 0)
      raise Invalid if current

      node
    end

    private

    def current
      @tokens[@index]
    end

    def take(kind = nil)
      token = current
      raise Invalid unless token && (kind.nil? || token.kind == kind)

      @index += 1
      token
    end

    def spelling(token)
      @text.byteslice(token.first...token.last).downcase
    end

    def expression(minimum, depth)
      raise Invalid if depth > 64

      left = primary(depth + 1)
      while current && (precedence = PRECEDENCE[current.kind]) && precedence >= minimum
        operator = take.kind
        right = expression(precedence + 1, depth + 1)
        left = Node.new(operator, left.first, right.last, [left, right])
      end
      left
    end

    def primary(depth)
      raise Invalid if depth > 64

      token = take
      case token.kind
      when '!'
        child = primary(depth + 1)
        return Node.new(:not, token.first, child.last, [child])
      when '('
        child = expression(1, depth + 1)
        last = take(')').last
        node = Node.new(:group, token.first, last, [child])
      when :name
        # A bare name is a known context, or a function immediately followed by `(`.
        # Property names are consumed separately below and are never function identities.
        if current&.kind == '('
          raise Invalid unless FUNCTIONS.key?(spelling(token))
        else
          raise Invalid unless CONTEXTS.include?(spelling(token))
        end
        node = Node.new(:name, token.first, token.last, [])
      when :literal
        node = Node.new(:literal, token.first, token.last, [])
      else
        raise Invalid
      end

      loop do
        case current&.kind
        when '.'
          # Runner token contexts forbid dereference/index directly after a literal.
          raise Invalid if node.kind == :literal

          take('.')
          part = take(:name) # Wildcards and literal-spelled properties are unsupported.

          node = Node.new(:access, node.first, part.last, [node])
        when '['
          raise Invalid if node.kind == :literal

          take('[')
          index = expression(1, depth + 1)
          node = Node.new(:access, node.first, take(']').last, [node, index])
        when '('
          # Actions functions are named calls, not arbitrary expression invocations.
          raise Invalid unless node.kind == :name

          take('(')
          arguments = []
          unless current&.kind == ')'
            loop do
              arguments << expression(1, depth + 1)
              break unless current&.kind == ','

              take(',')
            end
          end
          last = take(')').last
          raise Invalid unless FUNCTIONS.fetch(spelling(token)).cover?(arguments.length)

          node = Node.new(:call, node.first, last, arguments)
        else
          return node
        end
      end
    end
  end
end

# check-cache-policy.sh receives a raw, single-line `if:` line from its text walk.
# Decode YAML quoting here, preserving literal scalar padding and template boundaries.
# Keep this adapter out of the YAML checker's already-decoded entry point.
if $PROGRAM_NAME == __FILE__
  value = $stdin.read(8193)
  exit 1 if value.bytesize > 8192

  exit 1 unless value.match?(/\A[ \t]*if:[ \t]/) && !value.match?(/[\r\n]/)

  require 'yaml'
  begin
    doc = YAML.safe_load(value, aliases: false)
  rescue Psych::Exception
    exit 1
  end
  exit 1 unless doc.is_a?(Hash) && doc.keys == ['if']

  terms = CacheExpression.top_terms(doc['if'])
  exit 1 if terms.nil?

  puts terms
end
