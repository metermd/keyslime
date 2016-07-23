require 'fileutils'
require 'shellwords'

module Keyslime
  class Ramdisk
    ONE_MB = 1024 * 1024

    attr_reader :path
    attr_reader :size

    def initialize(path, size: ONE_MB)
      size = parse_byte_size(size) if size.is_a?(String)

      @path, @size = path, size

      if File.exist?(path) && !File.directory?(path)
        fail IOError, "Cannot create ramdisk at #{path}.  Exists."
      end

      FileUtils.mkdir_p(path) unless Dir.exist?(path)
    end

    def self.mounts
      %x(mount).each_line.map do |line|
        re = /\A([^\s]+) on (.+) type ([\w.-]+) \(([^)]*)\)\s*\z/
        if fields = line.match(re)
          { device:  fields[1],
            path:    fields[2],
            fs_type: fields[3],
            options: fields[4].split(',') }
        else
          fail RuntimeError, "didnt understand mount output: line=#{line}"
        end
      end
    end

    def mount_info
      self.class.all.find {|m| m[:path] == path }
    end

    def mounted?
      !! mount_info
    end

    def self.all
      mounts.select {|m| %w(ramfs tmpfs).include?(m[:fs_type]) }
    end

    def parse_byte_size(size_string)
      units = {
        b: 1,
        k: 1024,      m: 1024 ** 2, g: 1024 ** 3,
        t: 1024 ** 4, p: 1024 ** 5
      }

      if size_string.match(/\A(\d+)([#{units.keys.join}]?)\z/i)
        k = $2.empty? ? :b : $2.downcase.to_sym
        $1.to_i * units[k]
      else
        raise RuntimeError, "cant parse #{size_string}"
      end
    end

    def mount!
      fail "already mounted: #{path}" if mounted?

      command = [
        'mount',
          '-t', 'ramfs',
          '-o', "noexec,nodev,nosuid,rw,size=#{Shellwords.escape(size)}",
          'none',
          Shellwords.escape(path)
      ].join ' '

      %x(#{command})

      unless $?.success?
        fail "couldnt mount, command: #{command}"
      end
    end

    def umount!
      fail "not mounted: #{path}" unless mounted?

      command = "umount #{Shellwords.escape(path)}"
      %x(#{command})

      unless $?.success?
        fail "couldnt umount, command: #{command}"
      end
    end
  end
end
