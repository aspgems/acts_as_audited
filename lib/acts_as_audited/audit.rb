require 'set'

# Audit saves the changes to ActiveRecord models.  It has the following attributes:
#
# * <tt>auditable</tt>: the ActiveRecord model that was changed
# * <tt>user</tt>: the user that performed the change; a string or an ActiveRecord model
# * <tt>action</tt>: one of create, update, or delete
# * <tt>changes</tt>: a serialized hash of all the changes
# * <tt>created_at</tt>: Time that the change was performed
#
class Audit < ActiveRecord::Base
  belongs_to :auditable, :polymorphic => true
  belongs_to :user, :polymorphic => true

  before_create :set_version_number, :set_audit_user

  serialize :changes

  [:auditable_type, :auditable_id].each do |attr|
    named_scope "by_#{attr}".to_sym, lambda {|value|
      return if value.blank?
      { :conditions => { attr => value } }
    }
  end

  named_scope :between_dates, lambda {|begin_date, end_date|
    return if begin_date.blank? || end_date.blank?
    { :conditions => { :created_at => begin_date..end_date } }
  }

  named_scope :newer_than, lambda {|date|
    return if date.blank?
    { :conditions => [ 'audits.created_at >= ?', date ] }
  }

  named_scope :older_than, lambda {|date|
    return if date.blank?
    { :conditions => [ 'audits.created_at <= ?', date ] }
  }

  named_scope :by_name_or_title, lambda {|name, type|
    return if name.blank? || type.blank?
    table = type.split(':').last.tableize
    name_column = if type.constantize.column_names.include?('name')
      'name'
    elsif type.constantize.column_names.include?('title')
      'title'
    end
    return if name_column.blank?
    { :joins => "INNER JOIN #{table} "\
                "ON #{table}.id = audits.auditable_id",
      :conditions => ["#{table}.#{name_column} LIKE ?", "%#{name}%"]
    }
  }

  def self.search(params)
    return self if params.blank?
    begin_date = Time.zone.parse(params.begin_date.gsub('/','-')) if params.begin_date
    end_date = Time.zone.parse(params.end_date.gsub('/', '-')) if params.end_date
    by_auditable_type(params.auditable_type).
      by_auditable_id(params.auditable_id).
      by_name_or_title(params.auditable_name, params.auditable_type).
      between_dates(begin_date, end_date).
      newer_than(begin_date).
      older_than(end_date)
  end

  cattr_accessor :audited_class_names
  self.audited_class_names = Set.new

  def self.audited_classes
    self.audited_class_names.map(&:constantize)
  end

  cattr_accessor :audit_as_user
  self.audit_as_user = nil

  # All audits made during the block called will be recorded as made
  # by +user+. This method is hopefully threadsafe, making it ideal
  # for background operations that require audit information.
  def self.as_user(user, &block)
    Thread.current[:acts_as_audited_user] = user

    yield

    Thread.current[:acts_as_audited_user] = nil
  end

  # Allows user to be set to either a string or an ActiveRecord object
  def user_as_string=(user) #:nodoc:
    # reset both either way
    self.user_as_model = self.username = nil
    user.is_a?(ActiveRecord::Base) ?
      self.user_as_model = user :
      self.username = user
  end
  alias_method :user_as_model=, :user=
  alias_method :user=, :user_as_string=

  def user_as_string #:nodoc:
    self.user_as_model || self.username
  end
  alias_method :user_as_model, :user
  alias_method :user, :user_as_string

  def revision
    clazz = auditable_type.constantize
    returning clazz.find_by_id(auditable_id) || clazz.new do |m|
      Audit.assign_revision_attributes(m, self.class.reconstruct_attributes(ancestors).merge({:version => version}))
    end
  end

  def ancestors
    self.class.find(:all, :order => 'version',
      :conditions => ['auditable_id = ? and auditable_type = ? and version <= ?',
      auditable_id, auditable_type, version])
  end

  # Returns a hash of the changed attributes with the new values
  def new_attributes
    (changes || {}).inject({}.with_indifferent_access) do |attrs,(attr,values)|
      attrs[attr] = Array(values).last
      attrs
    end
  end

  # Returns a hash of the changed attributes with the old values
  def old_attributes
    (changes || {}).inject({}.with_indifferent_access) do |attrs,(attr,values)|
      attrs[attr] = Array(values).first
      attrs
    end
  end

  def self.reconstruct_attributes(audits)
    attributes = {}
    result = audits.collect do |audit|
      attributes.merge!(audit.new_attributes).merge!(:version => audit.version)
      yield attributes if block_given?
    end
    block_given? ? result : attributes
  end
  
  def self.assign_revision_attributes(record, attributes)
    attributes.each do |attr, val|
      if record.respond_to?("#{attr}=")
        record.attributes.has_key?(attr.to_s) ?
          record[attr] = val :
          record.send("#{attr}=", val)
      end
    end
    record
  end

private

  def set_version_number
    max = self.class.maximum(:version,
      :conditions => {
        :auditable_id => auditable_id,
        :auditable_type => auditable_type
      }) || 0
    self.version = max + 1
  end

  def set_audit_user
    self.user = Thread.current[:acts_as_audited_user] if Thread.current[:acts_as_audited_user]
    nil # prevent stopping callback chains
  end

end
