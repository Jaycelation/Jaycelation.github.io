# frozen_string_literal: true

AUTHORSHIP_LABELS = ['AI', 'Human', 'AI & Human'].freeze
SEASON_11_MACHINES = [
  'Reactor',
  'DevHub',
  'Connected',
  'Checkpoint',
  'Nimbus',
  'Enigma',
  'MakeSense',
  'Paperwork',
  'Bedside'
].freeze

Jekyll::Hooks.register :posts, :pre_render do |post|
  tags = Array(post.data['tags']).map(&:to_s)
  authorship_labels = tags & AUTHORSHIP_LABELS

  unless authorship_labels.one?
    raise Jekyll::Errors::FatalException,
          "#{post.relative_path} must have exactly one authorship tag: " \
          "#{AUTHORSHIP_LABELS.join(', ')}"
  end

  categories = Array(post.data['categories']).map(&:to_s)
  next unless categories.include?('HackTheBox')

  identity = [post.data['title'], post.basename_without_ext].join(' ')
  season_11_machine = SEASON_11_MACHINES.find do |machine|
    identity.match?(/\b#{Regexp.escape(machine)}\b/i)
  end

  next unless season_11_machine && !tags.include?('Season 11')

  raise Jekyll::Errors::FatalException,
        "#{post.relative_path} is a Season 11 #{season_11_machine} write-up " \
        "and must include the 'Season 11' tag"
end
