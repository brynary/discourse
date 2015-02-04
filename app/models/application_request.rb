class ApplicationRequest < ActiveRecord::Base
  enum req_type: %i(anon logged_in crawler)

  cattr_accessor :autoflush
  # auto flush if backlog is larger than this
  self.autoflush = 100

  def self.increment!(type, opts=nil)
    key = redis_key(type)
    val = $redis.incr(key).to_i
    $redis.expire key, 3.days

    autoflush = (opts && opts[:autoflush]) || self.autoflush
    if autoflush > 0 && val >= autoflush
      write_cache!
    end
  end

  def self.write_cache!(date=nil)
    if date.nil?
      write_cache!(Time.now.utc)
      write_cache!(Time.now.utc.yesterday)
      return
    end

    date = date.to_date

    # this may seem a bit fancy but in so it allows
    # for concurrent calls without double counting
    req_types.each do |req_type,_|
      key = redis_key(req_type,date)
      val = $redis.get(key).to_i

      next if val == 0

      new_val = $redis.incrby(key, -val).to_i

      if new_val < 0
        # undo and flush next time
        $redis.incrby(key, val)
        next
      end

      id = req_id(date,req_type)

      where(id: id).update_all(["count = count + ?", val])
    end
  end

  def self.clear_cache!(date=nil)
    if date.nil?
      clear_cache!(Time.now.utc)
      clear_cache!(Time.now.utc.yesterday)
      return
    end

    req_types.each do |req_type,_|
      key = redis_key(req_type,date)
      $redis.del key
    end
  end

  protected

  def self.req_id(date,req_type,retries=0)

    req_type_id = req_types[req_type]

    # a poor man's upsert
    id = where(date: date, req_type: req_type_id).pluck(:id).first
    id ||= create!(date: date, req_type: req_type_id, count: 0).id

  rescue # primary key violation
    if retries == 0
      req_id(date,req_type,1)
    else
      raise
    end
  end

  def self.redis_key(req_type, time=Time.now.utc)
    "app_req_#{req_type}#{time.strftime('%Y%m%d')}"
  end

end
