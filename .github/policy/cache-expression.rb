# frozen_string_literal: true

require 'strscan'

# A conservative subset of Actions expressions: literals, property/index access, calls,
# grouping, !, comparisons, && and ||. Unsupported or malformed syntax fails closed.
# Only exact, unparenthesised top-level conjuncts count as guards. Nothing is evaluated
# or deleted: a string's doubled quotes, parentheses and operators remain opaque tokens.
module CacheExpression
  class Invalid < StandardError; end
  Node = Struct.new(:kind, :first, :last, :children)
  Token = Struct.new(:kind, :first, :last)
  PRECEDENCE = { '||' => 1, '&&' => 2, '==' => 3, '!=' => 3,
                 '<' => 4, '<=' => 4, '>' => 4, '>=' => 4 }.freeze

  def self.top_terms(value)
    return nil unless value.is_a?(String) && value.length <= 8192 && !value.match?(/[\r\n]/)

    text = value.strip
    text = text[3...-2].strip if text.start_with?('${{') && text.end_with?('}}')
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
                 %w[true false null].include?(scan.matched) ? :literal : :name
               elsif scan.scan(/&&|\|\||==|!=|<=|>=|[!<>()\[\].,*]/)
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
      when :name, :literal
        node = Node.new(token.kind, token.first, token.last, [])
      else
        raise Invalid
      end

      loop do
        case current&.kind
        when '.'
          take('.')
          part = take
          raise Invalid unless [:name, '*'].include?(part.kind)

          node = Node.new(:access, node.first, part.last, [node])
        when '['
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
          node = Node.new(:call, node.first, take(')').last, arguments)
        else
          return node
        end
      end
    end
  end
end

# check-cache-policy.sh receives a raw, single-line `if:` line from its text walk.
# Keep this adapter out of the YAML checker's decoded-value entry point.
if $PROGRAM_NAME == __FILE__
  value = $stdin.read(8193)
  exit 1 if value.bytesize > 8192

  value = value.sub(/\A\s*if:\s*/, '')
  terms = CacheExpression.top_terms(value)
  exit 1 if terms.nil?

  puts terms
end
