$PACKAGES = %w(keyslime keyslime-common keyslime-client keyslime-server)

%w(build clean clobber install install:local release test).each do |metatask|
  desc "Execute `rake #{metatask}` for all sub-packages"
  task metatask do |t|
    $PACKAGES.each do |package|
      sh "cd #{package}; rake #{t}"
    end
  end
end
