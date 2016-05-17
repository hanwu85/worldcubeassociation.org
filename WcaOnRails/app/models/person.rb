class Person < ActiveRecord::Base
  self.table_name = "rails_persons"
  self.primary_key = "id"

  has_one :user, primary_key: "wca_id", foreign_key: "wca_id"
  has_many :results, primary_key: "wca_id", foreign_key: "personId"
  has_many :competitions, -> { distinct }, through: :results
  has_many :ranksAverage, primary_key: "wca_id", foreign_key: "personId", class_name: "RanksAverage"
  has_many :ranksSingle, primary_key: "wca_id", foreign_key: "personId", class_name: "RanksSingle"

  validates :name, presence: true
  validates :countryId, presence: true

  before_validation :unpack_dates
  private def unpack_dates
    if @dob.nil? && !dob.blank?
      @dob = dob.strftime("%F")
    end
    if @dob.blank?
      self.year = self.month = self.day = 0
    else
      unless /\A\d{4}-\d{2}-\d{2}\z/.match(@dob)
        errors.add(:dob, "is invalid")
        return false
      end
      self.year, self.month, self.day = @dob.split("-").map(&:to_i)
      unless Date.valid_date? self.year, self.month, self.day
        errors.add(:dob, "is invalid")
        return false
      end
    end
  end

  validate :dob_must_be_in_the_past
  private def dob_must_be_in_the_past
    if dob && dob >= Date.today
      errors.add(:dob, "must be in the past")
    end
  end

  # If someone represented country A, and now represents country B, it's
  # easy to tell which solves are which (results have a countryId).
  # Fixing their country (B) to a new country C is easy to undo, just change
  # all Cs to Bs. However, if someone accidentally fixes their country from B
  # to A, then we cannot go back, as all their results are now for country A.
  validate :cannot_change_country_to_country_represented_before, if: :countryId_changed?, unless: :new_record?
  private def cannot_change_country_to_country_represented_before
    has_been_a_citizen_of_this_country_already = Person.exists?(wca_id: wca_id, countryId: countryId)
    if has_been_a_citizen_of_this_country_already
      errors.add(:countryId, "Cannot change the country to a country the person have already represented in the past.")
    end
  end

  # This is necessary because we use a view instead of a real table.
  # Using `select` statement with `id` column causes mysql to set a default value of 0,
  # so creating a Person returns the new record with id = 0, making the record reference 'died'.
  # The workaround is to set id attribute to nil before the object is created and let Rails reload it after creation.
  # For reference: https://github.com/rails/rails/issues/5982
  before_create -> { self.id = nil }

  after_update :update_person_name_in_results_table, if: :name_changed?
  private def update_person_name_in_results_table
    results.where(personName: name_was).update_all(personName: name)
  end

  after_update :update_person_country_in_results_table, if: :countryId_changed?
  private def update_person_country_in_results_table
    results.where(countryId: countryId_was).update_all(countryId: countryId)
  end

  attr_reader :country_id_changed
  after_update -> { @country_id_changed = countryId_changed? }

  # Update the person attributes and save the old state as a new Person with greater subId.
  def update_using_sub_id(attributes)
    if attributes[:name] == self.name && attributes[:countryId] == self.countryId
      errors[:base] << "The name or the country must be different when updating the person."
      return false
    end
    old_attributes = self.attributes
    if update_attributes(attributes)
      Person.where(wca_id: wca_id).where.not(subId: 1).order(subId: :desc).update_all("subId = subId + 1")
      Person.create(old_attributes.merge!(subId: 2))
      return true
    end
  end

  def self.find_current_by_wca_id!(wca_id)
    find_by!(wca_id: wca_id, subId: 1)
  end

  def likely_delegates
    all_delegates = competitions.order(:year, :month, :day).map(&:delegates).flatten.select(&:any_kind_of_delegate?)
    if all_delegates.empty?
      return []
    end

    counts_by_delegate = all_delegates.each_with_object(Hash.new(0)) { |d, counts| counts[d] += 1 }
    most_frequent_delegate, _count = counts_by_delegate.max_by { |delegate, count| count }
    most_recent_delegate = all_delegates.last

    [ most_frequent_delegate, most_recent_delegate ].uniq
  end

  def sub_ids
    Person.where(wca_id: wca_id).map(&:subId)
  end

  attr_writer :dob

  def dob
    year == 0 || month == 0 || day == 0 ? nil : Date.new(year, month, day)
  end

  def country_iso2
    c = Country.find(countryId)
    c ? c.iso2 : nil
  end

  private def rank_for_event_type(event, type)
    case type
    when :single
      ranksSingle.find_by_eventId(event.id)
    when :average
      ranksAverage.find_by_eventId(event.id)
    else
      raise "Unrecognized type #{type}"
    end
  end

  def world_rank(event, type)
    rank = rank_for_event_type(event, type)
    rank ? rank.worldRank : nil
  end

  def best_solve(event, type)
    rank = rank_for_event_type(event, type)
    SolveTime.new(event.id, type, rank ? rank.best : 0)
  end

  def results_path
    "/results/p.php?i=#{self.wca_id}"
  end

  def serializable_hash(options = nil)
    json = {
      class: self.class.to_s.downcase,
      url: results_path,

      id: self.wca_id,
      wca_id: self.wca_id,
      name: self.name,

      gender: self.gender,
      country_iso2: self.country_iso2,
    }

    # If there's a user for this Person, merge in all their data,
    # the Person's data takes priority, though.
    (user || User.new).serializable_hash.merge(json)
  end
end
