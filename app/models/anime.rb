# == Schema Information
#
# Table name: anime
#
#  id                        :integer          not null, primary key
#  title                     :string(255)
#  alt_title                 :string(255)
#  slug                      :string(255)
#  age_rating                :string(255)
#  episode_count             :integer
#  episode_length            :integer
#  synopsis                  :text             default(""), not null
#  youtube_video_id          :string(255)
#  mal_id                    :integer
#  created_at                :datetime         not null
#  updated_at                :datetime         not null
#  cover_image_file_name     :string(255)
#  cover_image_content_type  :string(255)
#  cover_image_file_size     :integer
#  cover_image_updated_at    :datetime
#  bayesian_average          :float            default(0.0), not null
#  user_count                :integer          default(0), not null
#  thetvdb_series_id         :string(255)
#  thetvdb_season_id         :string(255)
#  english_canonical         :boolean          default(FALSE)
#  age_rating_guide          :string(255)
#  show_type                 :string(255)
#  started_airing_date       :date
#  finished_airing_date      :date
#  rating_frequencies        :hstore           default({}), not null
#  poster_image_file_name    :string(255)
#  poster_image_content_type :string(255)
#  poster_image_file_size    :integer
#  poster_image_updated_at   :datetime
#  cover_image_top_offset    :integer          default(0), not null
#  ann_id                    :integer
#  started_airing_date_known :boolean          default(TRUE), not null
#

class Anime < ActiveRecord::Base
  include PgSearch
  pg_search_scope :fuzzy_search_by_title, against: [:title, :alt_title],
    using: {trigram: {threshold: 0.1}}, ranked_by: ":trigram"
  pg_search_scope :simple_search_by_title, against: [:title, :alt_title],
    using: {tsearch: {normalization: 10, dictionary: "english"}}, ranked_by: ":tsearch"

  extend FriendlyId
  friendly_id :canonical_title, :use => [:slugged, :history]

  has_attached_file :cover_image,
    styles: {thumb: ["1400x900>", :jpg]},
    convert_options: {thumb: "-quality 70 -colorspace Gray"}

  validates_attachment :cover_image, content_type: {
    content_type: ["image/jpg", "image/jpeg", "image/png", "image/gif"]
  }

  has_attached_file :poster_image, default_url: "/assets/missing-anime-cover.jpg",
    styles: {large: "200x290!", medium: "100x150!"}

  validates_attachment :poster_image, content_type: {
    content_type: ["image/jpg", "image/jpeg", "image/png", "image/gif"]
  }


  def poster_image_thumb
    if self.poster_image_file_name.nil?
      "http://hummingbird.me/assets/missing-anime-cover.jpg"
    else
      # This disgusting fastpath brought to you by the following issue:
      # https://github.com/thoughtbot/paperclip/issues/909
      if Rails.env.production?
        "http://static.hummingbird.me/anime/poster_images/#{"%03d" % (self.id/1000000 % 1000)}/#{"%03d" % (self.id/1000 % 1000)}/#{"%03d" % (self.id % 1000)}/large/#{self.poster_image_file_name}?#{self.poster_image_updated_at.to_i}"
      else
        self.poster_image.url(:large)
      end
    end
  end

  has_many :quotes, dependent: :destroy
  has_many :castings, dependent: :destroy, as: :castable
  has_many :reviews, dependent: :destroy
  has_many :episodes, dependent: :destroy
  has_many :gallery_images, dependent: :destroy
  has_many :stories, as: :target, dependent: :destroy
  has_and_belongs_to_many :genres
  has_and_belongs_to_many :producers
  has_and_belongs_to_many :franchises

  has_many :watchlists, dependent: :destroy
  # has_many :consumings, as: :item TODO: this will be used once we decide to unify library stuff 
  validates :title, :presence => true, :uniqueness => true

  # Filter out hentai if `filterp` is true or nil.
  def self.sfw_filter(current_user)
    if current_user && !current_user.sfw_filter
      self
    else
      where("age_rating <> 'R18+'")
    end
  end

  # Check whether the current anime is SFW.
  def sfw?
    age_rating != "R18+"
  end

  def self.order_by_rating
    order('bayesian_average DESC NULLS LAST, user_count DESC NULLS LAST')
  end

  # Use this function to get the title instead of directly accessing the title.
  def canonical_title(title_language_preference=nil)
    if title_language_preference and title_language_preference.class == User
      title_language_preference = title_language_preference.title_language_preference
    end

    if title_language_preference and title_language_preference == "romanized"
      return title
    elsif title_language_preference and title_language_preference == "english"
      return (alt_title and alt_title.length > 0) ? alt_title : title
    else
      return (alt_title and alt_title.length > 0 and english_canonical) ? alt_title : title
    end
  end

  # Use this function to get the alt title instead of directly accessing the 
  # alt_title.
  def alternate_title(title_language_preference=nil)
    if title_language_preference and title_language_preference.class == User
      title_language_preference = title_language_preference.title_language_preference
    end

    if title_language_preference and title_language_preference == "romanized"
      return alt_title
    elsif title_language_preference and title_language_preference == "english"
      return (alt_title and alt_title.length > 0) ? title : nil
    else
      return english_canonical ? title : alt_title
    end
  end

  # Filter out all anime belonging to the genres passed in.
  def self.exclude_genres(genres)
    where('NOT EXISTS (SELECT 1 FROM anime_genres WHERE anime_genres.anime_id = anime.id AND anime_genres.genre_id IN (?))', genres.map(&:id))
  end

  # Find anime containing the genres passed in.
  # This complicated bit of SQL basically does relational division.
  def self.include_genres(genres)
    where('NOT EXISTS (
            SELECT * FROM genres AS g
            WHERE g.id IN (?)
            AND NOT EXISTS (
              SELECT *
              FROM anime_genres AS ag
              WHERE ag.anime_id = anime.id
              AND   ag.genre_id = g.id
            )
          )', genres.map(&:id))
  end

  def self.create_or_update_from_hash hash
    # First the creation logic
    # TODO: stop hard-coding the ID column
    anime = Anime.find_by(mal_id: hash[:external_id])
    if anime.nil? && Anime.where(title: hash[:title][:canonical]).count > 1
      log "Could not find unique Anime by title=#{hash[:title][:canonical]}.  Ignoring."
      return
    end
    anime ||= Anime.find_by(title: hash[:title][:canonical])
    anime ||= Anime.new

    # Metadata
    anime.assign_attributes({
      mal_id: (hash[:external_id] if anime.mal_id.blank?),
      title: (hash[:title][:canonical] if anime.title.blank?),
      alt_title: (hash[:title][:ja_en] if anime.alt_title.blank?),
      synopsis: (hash[:synopsis] if anime.synopsis.blank?),
      poster_image: (hash[:poster_image] if anime.poster_image.blank?),
      genres: (begin hash[:genres].map { |g| Genre.find_by name: g }.compact rescue [] end if anime.genres.blank?),
      producers: (begin hash[:producers].map { |p| Producer.find_by name: p }.compact rescue [] end if anime.producers.blank?),
      age_rating: (hash[:age_rating] if anime.age_rating.blank?),
      age_rating_guide: (hash[:age_rating_guide] if anime.age_rating_guide.blank?),
      episode_count: (hash[:episode_count] if anime.episode_count.blank?),
      episode_length: (hash[:episode_length] if anime.episode_length.blank?),
      started_airing_date: (begin hash[:dates][0] rescue nil end if anime.started_airing_date.blank?),
      finished_airing_date: (begin hash[:dates][1] rescue nil end if anime.finished_airing_date.blank?),
      show_type: (hash[:type] if anime.show_type.blank?)
    }.compact)
    anime.save!
    # Staff castings
    hash[:staff].each do |staff|
      Casting.create_or_update_from_hash staff.merge({
        castable: anime
      })
    end
    # VA castings
    hash[:characters].each do |ch|
      character = Character.create_or_update_from_hash ch
      if ch[:voice_actors].length > 0
        ch[:voice_actors].each do |actor|
          Casting.create_or_update_from_hash actor.merge({
            featured: ch[:featured],
            character: character,
            castable: anime
          })
        end
      else
        Casting.create_or_update_from_hash({
          featured: ch[:featured],
          character: character,
          castable: anime
        })
      end
    end
    anime
  end

  def show_type_enum
    ["OVA", "ONA", "Movie", "TV", "Special", "Music"]
  end

  def status
    # If the started_airing_date is in the future or not specified, the show hasn't
    # aired yet.
    if started_airing_date.nil? or started_airing_date > Time.now.to_date
      return "Not Yet Aired"
    end

    # Since the show's airing date is in the past, it has either "Finished Airing" or
    # is "Currently Airing".

    # If the show has only one episode, then it has "Finished Airing".
    if episode_count == 1
      return "Finished Airing"
    end

    # If the finished_airing_date is specified and in the future, the the show is
    # "Currently Airing". If it is specified and in the past, then the show has
    # "Finished Airing". If it is not specified, the show is "Currently Airing".
    if finished_airing_date.nil?
      return "Currently Airing"
    else
      if finished_airing_date > Time.now.to_date
        return "Currently Airing"
      else
        return "Finished Airing"
      end
    end
  end

  before_save do
    # If episode_count has increased, create new episodes.
    if self.episode_count and self.episodes.length < self.episode_count and (self.episodes.length == 0 or self.thetvdb_series_id.nil? or self.thetvdb_series_id.length == 0) 
      (self.episodes.length+1).upto(self.episode_count) do |n|
        Episode.create(anime_id: self.id, number: n)
      end
    end
  end

  after_save do
    Rails.cache.write("anime_poster_image_thumb:#{self.id}", self.poster_image.url(:large))
  end

  def similar(limit=20, options={})
    # FIXME
    return [] if Rails.env.development?

    exclude = options[:exclude] ? options[:exclude] : []
    similar_anime = []

    begin
      similar_json = JSON.load(open("http://app.vikhyat.net/anime_graph/related/#{self.id}")).select {|x| x["sim"] > 0.5 }.sort_by {|x| -x["sim"] }

      similar_json.each do |similar|
        sim = Anime.find_by_id(similar["id"])
        if sim and similar_anime.length < limit and (not self.sfw? or (self.sfw? and sim.sfw?))
          similar_anime.push(sim) unless exclude.include? sim
        end
      end
    rescue
    end

    similar_anime
  end
end
