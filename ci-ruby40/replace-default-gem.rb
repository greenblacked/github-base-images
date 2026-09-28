# Replace a Ruby default gem in place with a newer release: its library files,
# its compiled extensions, and its default gemspec.
#
#   ruby replace-default-gem.rb <name> <version> <install-dir>
#
# <install-dir> holds the newer release, installed there by
# `gem install --install-dir <install-dir> <name> --version <version>`.
#
# Why in place, rather than installing the newer gem next to the default one:
# Bundler resolves a default gem to its default gemspec and loads the copy in
# Ruby's own library directory, so with a newer gem merely installed alongside,
# plain `require` gets the new code while `bundle exec` still runs the old one.
# After this, there is one copy of the gem and every load path gets it: plain
# require, Bundler with the gem unlisted, and Bundler with it locked at the
# default version.
#
# Fails, rather than doing part of the job, when anything is not as expected.
require "fileutils"
require "rbconfig"

name, version, install_dir = ARGV
abort "usage: ruby replace-default-gem.rb <name> <version> <install-dir>" unless ARGV.size == 3

new_spec_path = File.join(install_dir, "specifications", "#{name}-#{version}.gemspec")
new_spec = Gem::Specification.load(new_spec_path) or abort "cannot load #{new_spec_path}"

default_dir = Gem.default_specifications_dir
old_paths = Dir[File.join(default_dir, "#{name}-*.gemspec")]
abort "expected exactly one default #{name} gemspec in #{default_dir}, found #{old_paths.size}" unless old_paths.size == 1
old_spec = Gem::Specification.load(old_paths.first) or abort "cannot load #{old_paths.first}"

libdir = RbConfig::CONFIG.fetch("rubylibdir")
archdir = RbConfig::CONFIG.fetch("rubyarchdir")

# Library files: remove every file the old default gem owned, then copy in the
# new release's lib/. Removing first means a file the new release dropped does
# not linger and get required by accident.
old_spec.files.each do |rel|
  path = File.join(libdir, rel)
  FileUtils.rm_f(path) if File.file?(path)
end
src = File.join(new_spec.full_gem_path, "lib")
abort "no lib/ in #{new_spec.full_gem_path}" unless File.directory?(src)
lib_files = Dir.glob("**/*", base: src).reject { |rel| File.directory?(File.join(src, rel)) || rel.end_with?(".so") }
abort "no library files in #{src}" if lib_files.empty?
lib_files.each do |rel|
  to = File.join(libdir, rel)
  FileUtils.mkdir_p(File.dirname(to))
  FileUtils.cp(File.join(src, rel), to)
end

# Compiled extensions: replace the old ones in the arch directory, at the same
# relative paths the default gem uses.
unless new_spec.extensions.empty?
  exts = Dir.glob("**/*.so", base: new_spec.extension_dir)
  abort "#{name} #{version} declares extensions but none were built in #{new_spec.extension_dir}" if exts.empty?
  exts.each do |rel|
    to = File.join(archdir, rel)
    FileUtils.mkdir_p(File.dirname(to))
    FileUtils.cp(File.join(new_spec.extension_dir, rel), to)
  end
end

# The default gemspec: same shape as the old one, new version and file list.
# This is what `gem list`, Bundler and scanners read.
old_spec.version = new_spec.version
old_spec.files = lib_files + old_spec.files.select { |f| f.start_with?("ext/") }
new_path = File.join(default_dir, "#{name}-#{version}.gemspec")
File.write(new_path, old_spec.to_ruby)
File.delete(old_paths.first) unless old_paths.first == new_path

puts "replaced default gem #{name} with #{version}: #{lib_files.size} library file(s), #{new_spec.extensions.empty? ? 0 : Dir.glob('**/*.so', base: new_spec.extension_dir).size} extension(s)"
