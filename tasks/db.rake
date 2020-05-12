namespace :db do

  task :sync => :environment do
    do_cleanup = ENV['clean'] == 'true'
    database = ENV['database']

    changes = SchemaSync.compute_changes(clean: do_cleanup, database: database)
    if changes.empty?
      puts "The schema is up-to-date."
      next
    end
    rs = SchemaSync.random_string(5)
    ms = SchemaSync.build_migrations(changes, {write: false, hash: rs, database: database})
    puts "========= Confirm the migration: ========"
    puts ms[:text]
    puts "========================================="

    print "Write changes? [Y/n]: "
    resp = STDIN.gets.chomp
    if resp == "Y" || resp == "y"
      ms = SchemaSync.build_migrations(changes, {write: true, hash: rs, database: database})
      fn = ms[:filename]
      puts "Migration written to #{fn}."

      print "Perform migration? [Y/n]: "
      resp = STDIN.gets.chomp
      if resp == "Y" || resp == "y"
        task = "db:migrate"
        if SchemaSync.has_multiple_databases?
          task = "db:migrate:#{database}"
        end
        Rake::Task[task].invoke
      end
    end
  end

end

