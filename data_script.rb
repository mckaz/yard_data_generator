require 'octokit'
require 'yard'
require 'google_drive'
require 'parser/current'
require 'digest/md5'
require 'csv'
require 'sequel'
require_relative 'type_converter.rb'

## See bottom of the file for the method calls that actually generate the data.



# This script will create, among other things, a dataset with YARD type data from
# the top X most starred Ruby repos on Github, and the top Y most downloaded gems
# on RubyGems.org.
# The resulting data set is a JSON file with the following structure:
#{ "program_name":
#        { "class_in_program":
#                { "method_in_class":
#                        { "attr_meth": Boolean,
#                          "params": { "param_name": { "type": "param_type",
#                                                      "doc": "param_documentation" },
#                                     },
#                          "return": { "type: "return_type", 
#                                      "doc": "return_documentation" },
#                          "source": "source_code",
#                          "source_tokenized": "tokenized_source_code",
#                          "docstring": "method_description"
#                         }
#                  }
#          }
#}



## name of github token file
GITHUB_TOKEN_FILE = "github-token"

## boolen indicating whether or not we want to upload to google_drive
USE_GOOGLE_DRIVE = false

## All programs are automatically uploaded to Google Drive in order to save
## their state.
## Currently, configuration is set for milod@umd.edu.
## Must change for other users.
GOOGLE_DRIVE_API_CONFIG = "config.json"

## Name of folder on Google Drive where data is stored.
GOOGLE_DRIVE_TYPE_FOLDER = "ruby-type-data"

## Name of json file where data is stored (locally).
TYPE_DATA_JSON_FILE = "type-data.json"

# A json file with the md5 hashes of all program files encountered.
# We use this to avoid adding duplicates to the dataset.
FILE_MD5_HASHES = "file_hashes.json"

## A directory where all individual program data will be stored.
DATA_DIR = "data"

## Program log contains information we want to save about each program and its data.
LOG_FILE = "program_log.csv"
LOG_HEADER = ["program name", "UID", "source", "github url", "branch", "commit", "gem version", "time accessed", "program type", "notes"]

## Rails gems exist separately, and together under `rails`. We use this list to avoid collecting their data twice.
RAILS_GEMS = ["actioncable", "actionmailbox", "actionmailer", "actionpack", "actiontext",
              "actionview", "activejob", "activemodel", "activerecord", "activestorage", "activesupport", "railties"]

## An error log for all types that could not be parsed.
ERROR_LOG = "errors.log"
DB_NAME = "rubygems"


DB = Sequel.postgres(database: "rubygems")
#query we want: DB[:gem_downloads].select{[Sequel[:gem_downloads][:rubygem_id], name, code, sum(count)]}.group_by(Sequel[:gem_downloads][:rubygem_id], :name, :code).join(:rubygems, id: :rubygem_id).join(:linksets, rubygem_id: :id).order(Sequel.desc(:sum)).limit(100).all
# to get octokit repo from url, use Octokit::Repoistory.from_url(URL_HERE).slug to get owner/name format,
# then call client.repository(owner/name)


## YARD creates default tags for struct member reader/writers.
## Redefining the below methods to turn off that default behavior.
module YARD::Handlers::Ruby::StructHandlerMethods
  def create_member_method?(*args)
    false
  end
end

$tokens = []

## tweak parser to output tokens
module PrintTokens
  def advance(*)
    token = super
    $tokens << [token[0], token[1][0]]
    token
  end
end

## Below is a bugfix.
## Without this, YARD tries treats
## directories beginning with "README"
## as files.
## This bug has been reported, but YARD has not fixed it.
module YARD
  module CLI
    class Yardoc
      def parse_arguments(*args)
        super(*args)

        # Last minute modifications
        self.files = Parser::SourceParser::DEFAULT_PATH_GLOB if files.empty?
        files.delete_if {|x| x =~ /\A\s*\Z/ } # remove empty ones
        readme = Dir.glob('README{,*[^~]}').
                 select { |fn| File.file? fn }. ## THIS LINE IS THE FIX
                 sort_by {|r| [r.count('.'), r.index('.'), r] }.first
        readme ||= Dir.glob(files.first).first if options.onefile && !files.empty?
        options.readme ||= CodeObjects::ExtraFileObject.new(readme) if readme
        options.files.unshift(options.readme).uniq! if options.readme

        Tags::Library.visible_tags -= hidden_tags
        add_visibility_verifier
        add_api_verifier

        apply_locale

        # US-ASCII is invalid encoding for onefile
        if defined?(::Encoding) && options.onefile
          if ::Encoding.default_internal == ::Encoding::US_ASCII
            log.warn "--one-file is not compatible with US-ASCII encoding, using ASCII-8BIT"
            ::Encoding.default_external, ::Encoding.default_internal = ['ascii-8bit'] * 2
          end
        end

        if generate && !verify_markup_options
          false
        else
          true
        end
      end
    end
  end
end



Parser::Lexer.prepend(PrintTokens)


## Create a client for acccessing Github.
## For different users, may need to change access token.
def create_client
  token = File.open(GITHUB_TOKEN_FILE).read
  Octokit::Client.new(access_token: token)
end

def search_repos(client, search, options = {})
  puts "Searching for repositories..."
  client.search_repositories(search, options)
end

def clone_repo(repo)
  puts "Cloning git repo #{repo[:name]} at #{repo[:repo][:clone_url]}..."
  system "git clone #{repo[:repo][:clone_url]} --depth 1"
end

def cleanup(repo_name)
  puts "Deleting repo #{repo_name}..."
  FileUtils.remove_dir(repo_name)  
end

def generate_yard_doc
  YARD::Registry.clear
  "Generating yard doc..."
  system "mv readme tmp_readme" if File.directory? "readme" ## "readme" directory triggers error in YARD
  YARD::CLI::Yardoc.run('-n')
  YARD::Registry.load
end

def load_yard_doc(file)
  YARD::Registry.clear
  "Loading yard doc..."
  YARD::Registry.load(file)
end


## Takes the methods represented in [+ meths +],
## and generates and returns a hash that has all the data we want (types, source code, documentation, etc.).
def get_yard_meths(meths, files = [])
  ## TODO: handle YARD options tags
  ## filter out meths without types
  meths.keep_if { |m| (!m.tags(:param).empty? && m.tags(:param).any? { |t| !t.types.nil? }) || (!m.tags(:return).empty? && m.tags(:return).any? { |t| !t.types.nil? }) } 

  ## these methods have types automatically generated for them based on their names
  ## for our purposes, not interested in these automatically generated types
  meths.keep_if { |m| !(m[:name] == :initialize) && !m[:name].to_s.end_with?("?") && !(m[:name] == :==) } 
  meths_hash = {}
  meths.each { |m|
    files << m.file unless files.include? m.file
    klass = m.namespace
    meth = m.name
    meths_hash[klass] ||= {} ## class
    meths_hash[klass][meth] ||= {} ## meth
    meths_hash[klass][meth][:attr_meth] = m.reader? || m.writer? ## %bool indicating whether meth is attribute reader or writer
    meths_hash[klass][meth][:params] ||= {} ## params
    m.tags(:param).each { |param|
      if param.types
        meths_hash[klass][meth][:params][param.name] = {}
        begin
          meths_hash[klass][meth][:params][param.name][:type] = YARDTC::Parser.parse(param.types) if param.types
        rescue SyntaxError
          File.open(ERROR_LOG, "a") { |f| f.puts("Class: #{m.namespace}, Method: #{meth}, Parameter: #{param.name}, Type: #{param.types}, File: #{m.file}") }
        end
        meths_hash[klass][meth][:params][param.name][:doc] = param.text.force_encoding 'utf-8' if param.text && !param.text.empty?
      end
    }
    m.tags(:return).each { |ret|
      ## should be at most 1 return type
      if ret.types
        meths_hash[klass][meth][:return] = {}
        begin
          meths_hash[klass][meth][:return][:type] = YARDTC::Parser.parse(ret.types) if ret.types          
        rescue SyntaxError
          File.open(ERROR_LOG, "a") { |f| f.puts("Class: #{m.namespace}, Method: #{meth}, Return, Type: #{ret.types}, File: #{m.file}") }
        end
        meths_hash[klass][meth][:return][:doc] = ret.text.force_encoding 'utf-8' if ret.text && !ret.text.empty?
      end
    }

    ## handle block types
    if m.tag(:yield) || !m.tags(:yieldparam).empty? || m.tag(:yieldreturn)
      meths_hash[klass][meth][:block] = {}
      meths_hash[klass][meth][:block][:doc] = m.tag(:yield).text if m.tag(:yield) && m.tag(:yield).text && !m.tag(:yield).text.empty?
      meths_hash[klass][meth][:block][:params] = {}        
      if !m.tags(:yieldparam).empty?
        m.tags(:yieldparam).each { |yp|
          if yp.types
            meths_hash[klass][meth][:block][:params][yp.name] = {}
            ## TODO: handle multiple types
            begin
              meths_hash[klass][meth][:block][:params][yp.name][:type] = YARDTC::Parser.parse(yp.types) if yp.types
            rescue SyntaxError
              File.open(ERROR_LOG, "a") { |f| f.puts("Class: #{m.namespace}, Method: #{meth}, Block Parameter: #{yp.name}, Type: #{yp.types}, File: #{m.file}") }
            end
            meths_hash[klass][meth][:block][:params][yp.name][:doc] = yp.text if yp.text && !yp.text.empty?
          end
        }
      end

      if (yr = m.tag(:yieldreturn))
        meths_hash[klass][meth][:block][:return] = {}
        ## TODO: handle multiple types
        begin
          meths_hash[klass][meth][:block][:return][:type] = YARDTC::Parser.parse(yr.types) if yr.types
        rescue SyntaxError
          File.open(ERROR_LOG, "a") { |f| f.puts("Class: #{m.namespace}, Method: #{meth}, Block Return, Type: #{yr.types}, File: #{m.file}") } 
        end
        meths_hash[klass][meth][:block][:return][:doc] = yr.text if yr.text && !yr.text.empty?
      end
      
    end

    ## m.source is the source code for the method
    ## m.is_explicit? is true iff the method is defined explicitly in source.
    ## e.g., attribute methods are often not explicitly defined.
    if m.source  && m.is_explicit?
      source = m.source.force_encoding 'utf-8'
      meths_hash[klass][meth][:source] = source
      begin
        parsed = Parser::CurrentRuby.parse source
        #meths_hash[klass][meth][:source_parsed] = parsed.to_s.force_encoding 'utf-8'
        meths_hash[klass][meth][:source_tokenized] = $tokens.to_s.force_encoding 'utf-8'
        $tokens = []
      rescue; end
    end
    meths_hash[klass][meth][:docstring] = m.docstring.force_encoding 'utf-8' if m.docstring
  }
  return meths_hash
end

## Ensure a file exists on Google Drive that has the name
## GOOGLE_DRIVE_TYPE_FOLDER.
def ensure_google_type_folder(session)
  session.folders.each { |f|
    return f if f.name == GOOGLE_DRIVE_TYPE_FOLDER
  }
  return session.create_folder(GOOGLE_DRIVE_TYPE_FOLDER)
end


## Compress [+ dirname +], upload it to [+ google_folder +].
def compress_and_upload(google_folder, dirname)
  puts "Compressing and uploading #{dirname} to Google Drive..."
  compressed_name = "#{dirname}.tar.gz"
  system "tar -czf #{compressed_name} #{dirname}"
  google_folder.upload_from_file(compressed_name)
  File.delete(compressed_name)
end

## Ensure local dir for storing data exists.
def ensure_data_folder
  return if File.directory? DATA_DIR
  Dir.mkdir DATA_DIR
end

## Ensure program log file exists.
def ensure_program_log_file
  return if File.file? LOG_FILE
  CSV.open(LOG_FILE, "wb") { |csv|
    csv << LOG_HEADER
  }
end

def change_to_repo_dir(repo_hash)
  if (repo_hash[:source] == "github")
    Dir.chdir[repo_hash[:name]]
  elsif (repo_hash[:source] == "rubygems")
    Dir.chdir["#{repo_hash[:name]}-#{repo_hash[:version]}"]
  else
    raise "Unexpected source of repo #{repo_hash[:name]}: #{repo_hash[:source]}"
  end
end

## Save program called [+ name +]'s data
## which is stored in [+ meths_hash +].
## Also saves [+ prog_log +], which contains the program log data,
## and [+ file_hashes +], which contains the md5 hashes of the program's files.
def save_app_data(name, meths_hash, prog_log, file_hashes)
  Dir.chdir(DATA_DIR)
  if !File.directory? name
    Dir.mkdir name
    Dir.chdir(name)
    YARD::Registry.save
    File.open(name + "-" + TYPE_DATA_JSON_FILE,"w") do |f|
      f.write(JSON.pretty_generate(meths_hash))
    end
    File.open(name + "-" + FILE_MD5_HASHES, "w") do |f|
      f.write(JSON.pretty_generate(file_hashes))
    end
    CSV.open(LOG_FILE, "wb") { |csv|
      csv << LOG_HEADER
      csv << prog_log
    }    
    Dir.chdir("../..")
  else
    Dir.chdir("..")
  end
end

def load_prog_log(path)
  log = CSV.read(path)
  ## first row is header, second row is data
  raise "Expected 2 rows in CSV file #{path}, got #{log.size} rows." unless log.size == 2
  return log[1]
end

# [+ client +] is Github client.
# [+ num_repos +] is Integer number of repos to return.
# returns Array<Hash>, where each hash has shape { name: String, source: "github", version: String, repo: Saywer::Resource, dir_name: String }
def get_github_list(client, num_repos)
  page = 1
  ret_repos = []
  until num_repos == 0
    repos = search_repos(client, "language:ruby", sort: "stars", page: page, per_page: 100)[:items]
    if repos.size >= num_repos
      ret_repos += repos[0..(num_repos - 1)].map { |r|
        commit_sha = client.commits(r[:full_name], r[:default_branch])[0][:sha]
        { name: r[:name], source: "github", version: commit_sha, repo: r, dir_name: r[:name] }
      }
      num_repos = 0
    else
      ret_repos += repos.map { |r|
        commit_sha = client.commits(r[:full_name], r[:default_branch])[0][:sha]
        { name: r[:name], source: "github", repo: r, version: commit_sha, dir_name: r[:name] }
      }
      num_repos -= 100
      page += 1
    end
  end
  ret_repos
end


# [+ num_repos +] is number of repos to be downloaded
# returns Array<Hash> where each Hash has shape { name: String, source: "rubygems", version: "String", dir_name: String }
def get_rubygems_list(num_repos)
  puts "Retrieving RubyGems #{num_repos} most downloaded repos..."
  repos = []
  return repos unless num_repos > 0
  ## get top N=num_repos most downloaded Ruby gems
  query_res = DB[:gem_downloads].select{[Sequel[:gem_downloads][:rubygem_id], name, code, sum(count)]}.group_by(Sequel[:gem_downloads][:rubygem_id], :name, :code).join(:rubygems, id: :rubygem_id).join(:linksets, rubygem_id: :id).order(Sequel.desc(:sum)).limit(num_repos).all

  return query_res.map { |r|
    gem_version = Gem.latest_spec_for(r[:name]).version.version       
    { name: r[:name], source: "rubygems", version: gem_version, dir_name: "#{r[:name]}-#{gem_version}" }
  }
end

## Generates program log information for [+ repo_hash +], a hash
## containing information about the program.
## The log information has the format shown in LOG_HEADER.
def get_prog_log(repo_hash)
  time = Time.now.getutc.to_s
  if (repo_hash[:source] == "github")
    [repo_hash[:name], repo_hash[:name].hash, repo_hash[:source], repo_hash[:repo][:html_url], repo_hash[:repo][:default_branch], repo_hash[:version], "", time, "", "", ""]
  elsif (repo_hash[:source] == "rubygems")
    [repo_hash[:name], repo_hash[:name].hash, repo_hash[:source], "", "", "", repo_hash[:version], time, "", ""]
  else
    raise "Unexpected source of repo #{r[:name]}: #{repo_hash[:source]}"
  end
end

## Downloads program represented by [+ repo_hash +].
def download_prog(repo_hash)
  if (repo_hash[:source] == "github")
    clone_repo(repo_hash)
  elsif (repo_hash[:source] == "rubygems")
    puts "Unpacking gem #{repo_hash[:name]}..."
    system "gem unpack #{repo_hash[:name]} --version #{repo_hash[:version]}"
  else
    raise "Unexpected source of repo #{repo_hash[:name]}: #{repo_hash[:source]}"
  end
end

# [+ github_num +] is number of top starred Ruby repos to look at on github
# [+ rubygem_num +] is number of top gems to look at on RubyGems
# Only repos that actually have YARD data are added to the data set.
def collection_loop(github_num, rubygem_num)
  client = create_client()
  if USE_GOOGLE_DRIVE
    google_session = GoogleDrive::Session.from_config(GOOGLE_DRIVE_API_CONFIG)
    type_folder = ensure_google_type_folder(google_session)
  end
  ensure_data_folder
  ensure_program_log_file
  apps_hash = File.file?(TYPE_DATA_JSON_FILE) ? JSON.parse(File.read(TYPE_DATA_JSON_FILE)): {}
  file_hashes = {}
  app_num = 0


  File.open(ERROR_LOG, "w") { |f| f.puts("ERRORS") }
  

  ## get list of github repos to download
  gh_list = get_github_list(client, github_num)

  # get list of rubygems repos to download
  rg_list = get_rubygems_list(rubygem_num)

  # combine them into a single program list
  prog_list = (gh_list + rg_list).uniq { |r| r[:name] }

  ## HACK: RAILS_GEMS are all included in rails already, similar with aws-sdk gems. Drop these from prog_list.
  prog_list.delete_if { |r| RAILS_GEMS.include?(r[:name]) || r[:name].start_with?("aws-sdk") || r[:name].start_with?("sys-proctable") }    

  prog_list.each { |r|
    puts "Working on app ##{app_num}..."
    ## HACK... have to look into these cases separately    
    next if ["libv8", "facter", "sixarm_ruby_unaccent"].include?(r[:name])
    
    if File.directory?("#{DATA_DIR}/#{r[:name]}")
      ## if data already exists for this program, then just load that data and update it.
      
      ## below commented out line uses existing json file
      #meths_hash = JSON.parse(File.read("#{DATA_DIR}/#{r[:name]}/#{r[:name]}-#{TYPE_DATA_JSON_FILE}"))
      puts "Found .yardoc file for app #{r[:name]}. Loading..."
      load_yard_doc("#{DATA_DIR}/#{r[:name]}/.yardoc")
      #prog_log = load_prog_log("#{DATA_DIR}/#{r[:name]}/log.csv")
      app_file_hashes = JSON.parse(File.read("#{DATA_DIR}/#{r[:name]}/#{r[:name]}-#{FILE_MD5_HASHES}"))
      file_hashes.merge!(app_file_hashes) { |k, v1, v2| v1 | v2 }

      ## get all YARD method data
      meths = YARD::Registry.all(:method)

      ## extract the data we want
      meths_hash = get_yard_meths(meths)

      ## store the method data in the app data (if there is any method data)
      apps_hash[r[:name]] = meths_hash if !meths_hash.empty?
    else
      ## if data doesn't already exist, generate and save it.
      
      #commit_sha = client.commits(r[:full_name], r[:default_branch])[0][:sha]
      #prog_log = [r[:name], r[:name].hash, r[:html_url], r[:default_branch], commit_sha, Time.now.getutc.to_s, "", ""]
      prog_log = get_prog_log(r)
      
      download_prog(r)
      Dir.chdir(r[:dir_name])

      app_file_hashes = {}
      
      ## YARD stuff here
      meth_files = []
      generate_yard_doc
      meths = YARD::Registry.all(:method)
      meths_hash = get_yard_meths(meths, meth_files)

      ## save to apps_hash, program log
      if !meths_hash.empty?
        apps_hash[r[:name]] = meths_hash
        CSV.open("../#{LOG_FILE}", "a+") { |csv|
          csv << prog_log
        }
      end

      ## collect MD5 hashes of all files in program
      meth_files.each do |f|
        next if f.nil? || !File.file?(f)
        key = Digest::MD5.hexdigest(IO.read(f))
        ## add file hash to both this app's hashes, and overall hashes
        if app_file_hashes.has_key?(key) then app_file_hashes[key].push(f) else app_file_hashes[key] = [f] end
        if file_hashes.has_key?(key) then file_hashes[key].push(f) else file_hashes[key] = [f] end
      end

      
      ## save app data files, and upload compressed app to google drive
      Dir.chdir("..")
      save_app_data(r[:name], meths_hash, prog_log, app_file_hashes)
      compress_and_upload(type_folder, r[:dir_name]) if USE_GOOGLE_DRIVE
      cleanup(r[:dir_name])
    end
    app_num += 1
  }

  ## write type data
  File.open(TYPE_DATA_JSON_FILE,"w") do |f|
    f.write(JSON.pretty_generate(apps_hash))
  end

  ## write file hashes
  File.open(FILE_MD5_HASHES, "w") do |f|
    f.write(JSON.pretty_generate(file_hashes))
  end

  return [apps_hash, file_hashes]
end

## Simple method to count how much data was actually created
def count_data(apps_hash)
  num_apps = apps_hash.size
  num_classes = num_meths = num_types =  0
  apps_hash.each { |_, klasses|
    num_classes += klasses.size
    klasses.each { |_, meths|
      num_meths += meths.size
      meths.each { |_, meth|
        num_types += meth["params"].size if meth["params"]
        num_types += 1 if meth["return"]
      }
    }
  }
  puts "Collected data from #{num_apps} apps, #{num_classes} classes, and #{num_meths} methods, comprising #{num_types} total types."
end

## Check file hashes to find if there were any duplicates.
## It's fine if there are a small number of duplicates across different apps.
## Mostly, we want to ensure we're not collecting data from the same app twice.
def find_dups(hash)
  open("dups.txt", 'w') do |f|
    f.puts '=== Identical Files ==='      
    hash.each_value do |a|
      next if a.length == 1
      a.each { |fname| f << ("\t" + fname) }
      f << "\n\n"
    end
  end
end


## The below calls are what actually collect data
## First arg is # github repos to look at, second is # rubygems to look at
apps_hash, file_hashes = collection_loop(1000, 1000)
count_data(apps_hash)
find_dups(file_hashes)
