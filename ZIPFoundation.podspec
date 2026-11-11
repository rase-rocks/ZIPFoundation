Pod::Spec.new do |s|
  s.name = 'ZIPFoundation'
  s.version = '1.0.0'
  s.license = 'MIT'
  s.summary = 'Effortless ZIP Handling in Swift'
  s.homepage = 'https://github.com/rase-rocks/ZIPFoundation'
  s.authors = { 'Thomas Zoechling' => 'thomas@peakstep.com' }
  s.source = { :git => 'https://github.com/rase-rocks/ZIPFoundation.git', :tag => s.version }
  s.swift_versions = ['6.0']

  s.ios.deployment_target = '15.0'
  s.osx.deployment_target = '12.0'
  s.tvos.deployment_target = '15.0'
  s.watchos.deployment_target = '9.0'
  s.visionos.deployment_target = '1.0'

  s.source_files = 'Sources/ZIPFoundation/*.swift'
  s.resource_bundles = {'ZIPFoundation_Privacy' => ['Sources/ZIPFoundation/Resources/PrivacyInfo.xcprivacy']}
end
