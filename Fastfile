default_platform(:ios)

platform :ios do
  lane :beta do
    increment_build_number
    build_app(scheme: "MyApp")
    upload_to_testflight

  lane :release do
    build_app(scheme: "MyApp")
  end
end
