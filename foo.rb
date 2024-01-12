def foo
  a.each do |x|
    x.each do |y|
      bar y
    end
  end
end
