cmake_minimum_required(VERSION 3.8)
project(tb3_sim)

find_package(ament_cmake REQUIRED)
find_package(ament_cmake_python REQUIRED)

ament_python_install_package(${PROJECT_NAME})

install(PROGRAMS
  tb3_sim/random_goal_sender.py
  DESTINATION lib/${PROJECT_NAME}
)

install(DIRECTORY
  launch
  worlds
  maps
  params
  urdf
  DESTINATION share/${PROJECT_NAME}
)

ament_package()
