require 'rugged'

module CapitalGit
  class LocalRepository

    # database is a CapitalGit::Database
    # name is the name of the git repo contained on that server
    def initialize database, name, options={}
      @db = database
      @name = name
      @directory = options["directory"] || ""
      @default_branch = options[:default_branch] || "master" # TODO: can we default to remote's default branch?

      @logger = CapitalGit.logger

      if repository.nil?
        @logger.info "Repository at #{local_path} doesn't exist"
        clone!
      end
    end

    attr_reader :name, :default_branch, :directory
    alias_method :slug, :name

    def local_path
      # File.expand_path(File.join("../..", "tmp", @name), File.dirname(__FILE__))
      File.join(@db.local_path, @name)
    end

    def remote_url
      "#{@db.connection_str}#{@name}.git"
    end

    def repository
      if @repository.nil?
        begin
          @repository = Rugged::Repository.new(local_path)
        rescue
          @logger.info "Failed to create repository from #{local_path}"
          @repository = nil
        end
      end
      @repository
    end

    def list(options={})
      pull!

      items = []
      repository.head.target.tree.walk_blobs do |root,entry|
        if root[0,@directory.length] == @directory
          if root.length > 0
            path = File.join(root, entry[:name])
          else
            path = entry[:name]
          end
          items << {:entry => entry, :path => path}
        end
      end

      items
    end

    def log(options={})
      limit = options[:limit] || 10

      pull!

      walker = Rugged::Walker.new(repository)
      walker.push(repository.head.target.oid)
      walker.sorting(Rugged::SORT_DATE)
      walker.push(repository.head.target)
      walker.map do |commit|
        {
          :message => commit.message,
          :author => commit.author,
          :time => commit.time,
          :oid => commit.oid
        }
      end.compact.first(limit)
    end

    # TODO
    # be able to specify separate refs to pull
    # 
    # what to return when file doesn't exist?
    def read(key, options={})
      pull!

      resp = {}

      repository.head.target.tree.walk_blobs do |root,entry|
        if (root.empty? && (entry[:name] == key)) or 
            ((root[0,@directory.length] == @directory) && (File.join(root, entry[:name]) == key))
          blob = repository.read(entry[:oid])
          resp[:value] = blob.data.force_encoding('UTF-8')
          resp[:entry] = entry
          walker = Rugged::Walker.new(repository)
          walker.push(repository.head.target.oid)
          walker.sorting(Rugged::SORT_DATE)
          walker.push(repository.head.target)
          resp[:commits] = walker.map do |commit|
            # if commit.parents.size == 1 && commit.diff(paths: [key]).size > 0
            if commit.diff(paths: [key]).size > 0
              {
                :message => commit.message,
                :author => commit.author
              }
            else
              nil
            end
          end.compact.first(10)
        end
      end

      if resp.empty?
        return nil
      else
        return resp
      end
    end

    # TODO make it possible to commit to something other than HEAD
    # TODO detect when nothing changed and don't commit if so
    def write(key, value, options={})
      updated_oid = repository.write(value, :blob)
      tree = repository.head.target.tree

      commit_options = {}
      commit_options[:tree] = update_tree(repository, tree, key, updated_oid)
      commit_options[:author] = options[:author] || @db.committer # TODO: some sort of author instead
      commit_options[:committer] = @db.committer || options[:author]
      commit_options[:message] = options[:message] || ""
      commit_options[:parents] = repository.empty? ? [] : [ repository.head.target ].compact
      commit_options[:update_ref] = 'HEAD'

      commit_oid = Rugged::Commit.create(repository, commit_options)

      if !repository.bare?
        repository.reset(commit_oid, :hard)
        push!
      end

      # repository.head.target.to_hash
      if repository.head.target.oid == commit_oid
        return true
      else
        return false
      end
    end

    # TODO: refactor so delete and write share code

    # delete a specific file
    def delete(key, options={})
      tree = repository.head.target.tree
      original_oid = repository.head.target.oid

      commit_options = {}
      commit_options[:tree] = update_tree(repository, tree, key, nil)
      commit_options[:author] = options[:author] || @db.committer # TODO: some sort of author instead
      commit_options[:committer] = @db.committer || options[:author]
      commit_options[:message] = options[:message] || ""
      commit_options[:parents] = repository.empty? ? [] : [ repository.head.target ].compact
      commit_options[:update_ref] = 'HEAD'

      # if nothing changed, don't commit
      if tree.oid == commit_options[:tree]
        return false
      end

      commit_oid = Rugged::Commit.create(repository, commit_options)

      if !repository.bare?
        repository.reset(commit_oid, :hard)
        push!
      end

      # puts original_oid
      # puts commit_oid
      # puts tree.oid
      # puts commit_options[:tree]

      # repository.head.target.to_hash
      if repository.head.target.oid == commit_oid
        return true
      else
        return false
      end
    end

    # delete everything under a directory
    def clear(key, options={})
      raise "Not implemented"
    end


    # methods for interacting with remote

    def pull!
      if repository.nil?
        @logger.info "Repository at #{local_path} doesn't exist"
        return clone!
      else
        remote = repository.remotes.find {|r| r.name == "origin"}
        @logger.info "Fetching #{remote.name} into #{local_path}"
        opts = {}
        opts[:credentials] = @db.credentials if @db.credentials
        opts[:update_tips] = lambda do |ref, old_oid, new_oid|
          if (ref.gsub("refs/remotes/#{remote.name}/","") == default_branch)
            @logger.info "Updated #{ref} from #{old_oid} to #{new_oid}"
            repository.reset(new_oid, :hard)
          end
        end
        remote.fetch(opts)
      end
    end

    def push!
      if !repository.nil?
        remote = repository.remotes.find {|r| r.name == "origin"}
        @logger.info "Pushing #{local_path} to #{remote.name}"
        opts = {}
        opts[:credentials] = @db.credentials if @db.credentials
        remote.push([repository.head.name], opts)
      end
    end


    private

    def clone!
      opts = {}
      opts[:checkout_branch] = default_branch if default_branch
      opts[:credentials] = @db.credentials if @db.credentials

      @logger.info "Cloning #{remote_url} (#{default_branch}) into #{local_path}"
      Rugged::Repository.clone_at(remote_url, local_path, opts)
    end

    # recursively updates a tree.
    # returns the oid of the new tree
    # blob_oid is either an object id to the file blob
    # or if nil, that path is removed from the tree    
    def update_tree repo, tree, path, blob_oid
      segments = path.split("/")
      segment = segments.shift
      if tree
        builder = Rugged::Tree::Builder.new(repo, tree)
      else
        builder = Rugged::Tree::Builder.new(repo)
      end
      if segments.length > 0
        rest = segments.join("/")
        if builder[segment]
          # puts '1', segment, rest
          original_tree = repo.lookup(builder[segment][:oid])
          

          # Throws error instead of returning false, but that's a rugged bug
          # fixed in https://github.com/libgit2/rugged/pull/521
          # can do this instead of explicitly testing for existence of segment
          builder.remove(segment) 

          new_tree = update_tree(repo, original_tree, rest, blob_oid)
          builder << { :type => :tree, :name => segment, :oid => new_tree, :filemode => 0040000 }
          return builder.write
        else
          # puts '2', segment, rest
          new_tree = update_tree(repo, nil, rest, blob_oid)
          builder << { :type => :tree, :name => segment, :oid => new_tree, :filemode => 0040000 }
          return builder.write
        end
      else
        if builder[segment]
          builder.remove(segment) # Throws error instead of returning false, but that's a rugged bug
          # TODO: after https://github.com/libgit2/rugged/pull/521 is released, can remove conditional check
        end
        if !blob_oid.nil?
          builder << { :type => :blob, :name => segment, :oid => blob_oid, :filemode => 0100644 }
        end
        return builder.write
      end
    end

  end
end