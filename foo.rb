# frozen_string_literal: true

class Foo
  def foo(arg)
    pp arg
  end
end

class Bar < Foo
  def foo(arg)
   super(arg)
  end
end
