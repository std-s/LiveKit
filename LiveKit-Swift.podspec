#
# Be sure to run `pod lib lint LiveKit.podspec' to ensure this is a
# valid spec before submitting.
#
# Any lines starting with a # are optional, but their use is encouraged
# To learn more about a Podspec see https:#

Pod::Spec.new do |s|
  s.name             = 'LiveKit-Swift'
  s.version          = '1.0.0'
  s.summary          = '为支持cocoapods'

# This description is used to generate tags and improve search results.
#   * Think: What does it do? Why did you write it? What is the focus?
#   * Try to keep it short, snappy and to the point.
#   * Write the description between the DESC delimiters below.
#   * Finally, don't worry about the indent, CocoaPods strips it!

  s.description      = <<-DESC
                       DESC

  s.homepage         = 'https://www.rentsoft.cn/'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'rentsoft' => 'https://www.rentsoft.cn/' }
  s.source           = { :git => 'https://github.com/std-s/LiveKit.git', :tag => s.version.to_s }

  s.ios.deployment_target = '13.0'

  s.source_files = 'LiveKit/**/*'

  s.static_framework = true 
  s.dependency 'WebRTC-SDK', '97.4692.05'
  s.dependency 'SwiftProtobuf', '1.18.0'
  s.dependency 'PromisesSwift', '2.0.0'
  s.dependency 'SwiftLog'
end
