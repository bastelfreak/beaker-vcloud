require 'rspec/core/rake_task'

namespace :test do
  namespace :spec do
    desc "Run spec tests"
    RSpec::Core::RakeTask.new(:run) do |t|
      t.rspec_opts = ['--color']
      t.pattern = 'spec/'
    end
  end
end

# namespace-named default tasks.
# these are the default tasks invoked when only the namespace is referenced.
# they're needed because `task :default` in those blocks doesn't work as expected.
task 'test:spec' => 'test:spec:run'

# global defaults
task :test => 'test:spec'
task :default => :test

###########################################################
#
#   Documentation Tasks
#
###########################################################
DOCS_DAEMON = "yard server --reload --daemon --server thin"
FOREGROUND_SERVER = 'bundle exec yard server --reload --verbose --server thin lib/beaker'

def running?( cmdline )
  ps = `ps -ef`
  found = ps.lines.grep( /#{Regexp.quote( cmdline )}/ )
  if found.length > 1
    raise StandardError, "Found multiple YARD Servers. Don't know what to do."
  end

  yes = found.empty? ? false : true
  return yes, found.first
end

def pid_from( output )
  output.squeeze(' ').strip.split(' ')[1]
end

desc 'Start the documentation server in the foreground'
task :docs => 'docs:clear' do
  original_dir = Dir.pwd
  Dir.chdir( File.expand_path(File.dirname(__FILE__)) )
  sh FOREGROUND_SERVER
  Dir.chdir( original_dir )
end

namespace :docs do

  desc 'Clear the generated documentation cache'
  task :clear do
    original_dir = Dir.pwd
    Dir.chdir( File.expand_path(File.dirname(__FILE__)) )
    sh 'rm -rf docs'
    Dir.chdir( original_dir )
  end

  desc 'Generate static documentation'
  task :gen => 'docs:clear' do
    original_dir = Dir.pwd
    Dir.chdir( File.expand_path(File.dirname(__FILE__)) )
    output = `bundle exec yard doc`
    puts output
    if output =~ /\[warn\]|\[error\]/
      fail "Errors/Warnings during yard documentation generation"
    end
    Dir.chdir( original_dir )
  end

  desc 'Run the documentation server in the background, alias `bg`'
  task :background => 'docs:clear' do
    yes, output = running?( DOCS_DAEMON )
    if yes
      puts "Not starting a new YARD Server..."
      puts "Found one running with pid #{pid_from( output )}."
    else
      original_dir = Dir.pwd
      Dir.chdir( File.expand_path(File.dirname(__FILE__)) )
      sh "bundle exec #{DOCS_DAEMON}"
      Dir.chdir( original_dir )
    end
  end

  task(:bg) { Rake::Task['docs:background'].invoke }

  desc 'Check the status of the documentation server'
  task :status do
    yes, output = running?( DOCS_DAEMON )
    if yes
      pid = pid_from( output )
      puts "Found a YARD Server running with pid #{pid}"
    else
      puts "Could not find a running YARD Server."
    end
  end

  desc "Stop a running YARD Server"
  task :stop do
    yes, output = running?( DOCS_DAEMON )
    if yes
      pid = pid_from( output )
      puts "Found a YARD Server running with pid #{pid}"
      `kill #{pid}`
      puts "Stopping..."
      yes, output = running?( DOCS_DAEMON )
      if yes
        `kill -9 #{pid}`
        yes, output = running?( DOCS_DAEMON )
        if yes
          puts "Could not Stop Server!"
        else
          puts "Server stopped."
        end
      else
        puts "Server stopped."
      end
    else
      puts "Could not find a running YARD Server"
    end
  end
end
