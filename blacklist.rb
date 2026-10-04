# frozen_string_literal: true

require_relative 'logger'

# Parses and evaluates e621-style blacklist rules.
#
# Each non-blank, non-comment line is a rule.  Tags on the same line are AND'd
# unless prefixed with ~ (OR group) or - (negation).  If a ~group exists, at
# least one member must match.  If a -tag is present, the rule does NOT match.
#
#   gore                  → blacklist all gore posts
#   female fox nude       → blacklist if ALL three are present
#   pokémon -pikachu      → blacklist pokémon UNLESS pikachu is also present
#   ~wolf ~lion           → blacklist if EITHER wolf OR lion is present
#   rating:e              → blacklist all explicit posts
#   id:12345              → blacklist a specific post
#
class Blacklist
  include Rubichiver::Logging

  Rule = Struct.new(:required, :optional_or, :forbidden)

  def initialize(file)
    @rules = []
    load(file) if file && File.exist?(file)
  end

  def any?
    @rules.any?
  end

  def blacklisted?(tag_set, rating, post_id)
    @rules.any? { |rule| matches_rule?(rule, tag_set, rating, post_id) }
  end

  private

  UNSUPPORTED_TAG = /\A-?(?:userid|uploader):\d+\z/.freeze

  RATING_ABBREV = {
    'safe' => 'safe', 's' => 'safe', 'g' => 'safe',
    'questionable' => 'questionable', 'q' => 'questionable',
    'explicit' => 'explicit', 'e' => 'explicit',
    'sensitive' => 'sensitive'
  }.freeze

  def load(file)
    File.foreach(file) do |line|
      line = line.strip
      next if line.empty? || line.start_with?('#')

      tags = line.split
      required = []
      optional_or = []
      forbidden = []
      unsupported = []

      tags.each do |tag|
        if tag.match?(UNSUPPORTED_TAG)
          unsupported << tag
          next
        end
        if tag.start_with?('~')
          optional_or << tag[1..]
        elsif tag.start_with?('-')
          forbidden << tag[1..]
        else
          required << tag
        end
      end

      if unsupported.any?
        log_warn "Blacklist rule contains unsupported tag(s), ignored", rule: line, ignored: unsupported.join(', ')
      end

      # A rule with only unsupported components cannot match; discard it
      # to avoid blacklisting everything.
      next if required.empty? && optional_or.empty? && forbidden.empty?

      @rules << Rule.new(required, optional_or, forbidden)
    end
  end

  def tag_matches?(tag, tag_set, rating, post_id)
    case tag
    when /\Arating:(safe|questionable|explicit|sensitive|[sqeg])\z/
      RATING_ABBREV[rating] == RATING_ABBREV[$1]
    when /\Aid:(\d+)\z/
      post_id == $1.to_i
    when /\A(?:-)?(?:userid|uploader):\d+\z/
      false
    else
      return true if tag_set.include?(tag)
      if tag.include?(':')
        bare = tag.split(':', 2).last
        return true if tag_set.include?(bare)
      end
      false
    end
  end

  def matches_rule?(rule, tag_set, rating, post_id)
    rule.required.each do |tag|
      return false unless tag_matches?(tag, tag_set, rating, post_id)
    end

    if rule.optional_or.any?
      return false unless rule.optional_or.any? { |tag| tag_matches?(tag, tag_set, rating, post_id) }
    end

    rule.forbidden.each do |tag|
      return false if tag_matches?(tag, tag_set, rating, post_id)
    end

    true
  end
end
